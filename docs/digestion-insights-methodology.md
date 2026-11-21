# Digestion Insights methodology

Engine: `Packages/DigestionInsights` (library `DigestionInsightsEngine`).
Simulation study: [Packages/DigestionInsights/Simulation/results.md](../Packages/DigestionInsights/Simulation/results.md),
generated from `results.json` in the same folder.

This document explains what Digestion Insights does with a user's symptom and meal logs, which
statistical model it fits, how the fit is checked, and what a simulation study says about how well
it works. App behaviour described here (logging screens, evidence levels, nightly runs) follows the
feature's design decisions. The app code that implements it lands separately, so types are named
in code font without links. Every number in the validation section comes from `results.md`.

---

## 1. Purpose and limits

Digestion Insights is an opt-in feature. A user logs digestive symptoms; the app compares them with
the nutrition journal the user already keeps and looks for ingredients that symptoms tend to
follow, and for roughly how many hours after eating. The result per ingredient is a pattern level,
an effect size with an interval, a typical delay and two charts.

It is pattern matching on one person's own records. It is not a diagnosis and it never names a
mechanism: the app does not say "lactose intolerance", "FODMAP", "fructans" or "allergy". It never
suggests cutting out a food or trying an elimination diet. Where a pattern is strong enough to
report, the wording is "Worth discussing with your doctor." When the data show no effect, the
wording is "No link found", never "safe".

Every screen that shows analysis results also says two things: AI meal recognition makes mistakes,
and the results are statistics, not medical data.

The model looks at most 96 hours back from each symptom. Effects that build up over more than 96
hours (for example over days of repeated eating) are outside its scope, and the app says so
plainly.

The feature is off by default. Nothing about symptoms appears on any main screen, and it sends no
reminders, check-ins or notifications.

Results are shown only from a run whose sampler passed every convergence check (section 5). There
are no time gates: the app never waits a fixed number of weeks before showing something, and it
never shows a finding just because enough time has passed.

---

## 2. Data

### 2.1 Symptoms

Six symptom kinds, each with ordered levels (`SymptomKind`, `SymptomLevel`):

| Kind | Levels, low to high |
|---|---|
| Abdominal pain | Noticeable, Bothersome, Disrupted my day |
| Bloating | Mild, Severe |
| Diarrhoea | Loose, Watery |
| Gas | More than usual (no level choice) |
| Nausea | Mild, Severe |
| Heartburn | Mild, Severe |

A symptom entry (`SymptomEntry`) stores its onset time, the time it was logged, kind and level.
The onset picker offers Now, 1 h ago, 3 h ago and Earlier… (a date picker limited to the current
tracking period). The model uses onset times only; levels are kept for display and export.

Logging happens only through the Nutrition tab toolbar ("Log symptom…"). There are no widgets,
Control Centre controls, Siri intents or Apple Watch logging.

### 2.2 Observation rule

Only symptoms are logged, so "no entry" has to mean something. The rule is:

- Tracking runs in periods (`DigestionTrackingPeriod`): "Start tracking" opens one, turning the
  setting off closes it. Time between periods is not observed, and there is no backfill.
- Inside a period, a calendar day with at least one logged meal and no symptom entry counts as
  symptom-free.
- A day without any logged meal is not observed at all: neither symptom-free nor symptomatic.
- Meals from the 96 hours before a period starts count as exposure history only, so that symptoms
  early in the period can be related to what was eaten just before it.

The engine receives these as observation windows (`ObservationWindow`): an hour belongs to the data
when its centre lies inside a window.

### 2.3 Ingredient data

Each logged meal may carry an ingredient profile (`IngredientProfile`, stored as JSON on the
nutrition entry). No profile means no exposures, but the meal still marks its day as observed.
Profiles come from two places:

- **Open Food Facts** (barcode or search followed by a product lookup). The app reads the
  declared EU allergens (`allergens_tags`), "may contain" traces (`traces_tags`, EU allergens only),
  the ingredient list as taxonomy IDs, free-from labels (`labels_tags`), alcohol
  (`alcohol_100g` above 0.5 or label `en:contains-alcohol`), and Open Food Facts' own completeness
  information: an ingredient list counts as complete when `states_tags` contains
  `en:ingredients-completed` and `unknown_ingredients_n` is 0. The app does not invent its own
  data-quality score.
- **Photo AI.** The meal-photo model also returns likely EU allergens and up to 15 ingredient
  names, which the app matches to taxonomy IDs. The user can correct detected allergens and
  free-from marks.

The 14 EU allergens use Open Food Facts allergen IDs (`EUAllergen`), for example `en:gluten`,
`en:milk`, `en:nuts` (tree nuts), `en:sulphur-dioxide-and-sulphites`.

### 2.4 Taxonomy, catalogue and roll-up

The app bundles a trimmed copy of the Open Food Facts ingredients taxonomy (about 6,900 entries
with English and German names and parent links; data under the Open Database Licence). Ingredient
names are matched by exact normalised name (lower case, trimmed, single spaces), English first,
then German, then once more without a trailing "s". Nothing fuzzier: the taxonomy file has no
synonym lists, so a name the taxonomy does not know stays unmatched and is never analysed.

A fixed catalogue (`DigestionCatalog`) lists up to 80 common **base** foods and up to 25 food
**groups** (for example onion family, dairy, cheese, legumes, brassicas, alcohol). Catalogue
entries were chosen for how common and recognisable a food is, never because it is a suspected
trigger. Each ingredient rolls up through its taxonomy ancestors:

- ingredient features: the catalogue bases among the ingredient and its ancestors; if there is
  none, the ingredient itself;
- group features: the catalogue groups among the ingredient and its ancestors.

So onion powder counts as `ingredient:en:onion` and `group:en:onion-family-vegetable`; tomato,
which has no base above it, counts as `ingredient:en:tomato`.

### 2.5 Evidence levels and free-from variants

Every exposure carries a value that the model reads as exposure intensity, roughly "how sure are
we the meal contained it":

| Level | Value | Source |
|---|---|---|
| L1 | 1.0 | Allergen declared by Open Food Facts or set by the user; alcohol from Open Food Facts |
| L2 | 0.85 | Ingredients from a complete Open Food Facts ingredient list |
| L3 | 0.5 | Traces; allergens detected by photo AI; ingredients from photos; ingredients from an incomplete Open Food Facts list; alcohol inferred from a photo |

Per meal and feature the highest value counts. These constants are fixed for everyone, never tuned
per user.

Exposure is presence only. A spoonful and a plateful count the same (section 9 describes the
amount-based alternative as a future test).

Free-from labels split a feature. A meal marked lactose-free counts as
`allergen:en:milk+free:en:no-lactose` instead of `allergen:en:milk`; likewise gluten-free splits
gluten, alcohol-free splits alcohol, and decaf splits coffee. Display names get a suffix such as
"(lactose-free)".

Feature IDs are `allergen:<id>`, `ingredient:<taxonomy id>`, `group:<taxonomy id>` and `alcohol`.

---

## 3. Model

### 3.1 Likelihood

The data are hourly. For every observed absolute hour h (hours since 1970, UTC) and symptom kind s,
y[h, s] is the number of logged symptom onsets. The model is a Poisson regression with log link:

```
y[h, s] ~ Poisson(exp η[h, s])

η[h, s] = α_s + tod(h) + drift(h) + Σ_f Σ_k X[h, f, k] · (b[f, k] + d[f, s, k])
```

- α_s: baseline log rate of kind s.
- tod(h): time of day, two Fourier harmonics (four coefficients γ), shared by all kinds. It uses
  the UTC hour; a constant time-zone offset only shifts the phase. Travel across time zones is not
  modelled.
- drift(h): slow change of the baseline over the tracking period, a cubic B-spline over days with
  about one knot per 30 days, shared by all kinds.
- X[h, f, k]: the distributed-lag cross-basis (3.2).
- b[f, ·]: the shared lag curve of feature f; d[f, s, ·]: its deviation for kind s. One model
  covers all kinds, so a food that affects only diarrhoea can still borrow strength from the other
  kinds' data for its baseline.

### 3.2 Distributed-lag cross-basis

For each exposure e of feature f at time t_e with value v_e, and each observed hour h whose
centre lies 0 to 96 hours later:

```
X[h, f, k] = Σ_e v_e · B_k(lag),    lag = (h + 0.5) − t_e   in hours,  0 ≤ lag < 96
```

B_1 … B_8 is a cubic B-spline basis on [0, 96] h with interior knots at 3, 8, 24 and 48 h, so the
lag curve is flexible in the first hours and smoother further out. There are no fixed windows or
bins. The effect of one exposure on the log rate at lag l is

```
β_f,s(l) = Σ_k B_k(l) · (b[f, k] + d[f, s, k])
```

and overlapping exposures add on the log scale (their rate ratios multiply). This is the
distributed-lag model of Gasparrini et al. (2010, 2017), applied to individual meal times instead
of daily series.

Cross-basis and drift columns are centred over the rows of each fit. This only re-parametrises the
intercepts (α_s then refers to the rate at average exposure) and leaves b and d unchanged. Without
it, flat lag curves and α sat on a curved ridge and the sampler diverged.

Features with fewer than 5 exposures in the observed period are left out of the fit and reported
as "not enough data".

### 3.3 Priors

All positive scales are sampled on the log scale (with Jacobian), and all lag coefficients are
non-centred (z ~ N(0, I) times a scale).

```
b_f  = s_f · C z_f              s_f  = slab(τ_g · λ_f)
d_fs = s'_f · C z_fs            s'_f = slab(λ_f · σ_d)

τ_g ~ HalfNormal(0.5)           global scale, shared by all features
λ_f ~ HalfCauchy(1)             local scale per feature (horseshoe)
σ_d ~ HalfNormal(1)             scale of the per-kind deviations

slab(x) = c x / √(c² + x²),     c = 1

C = chol((ωP + diag κ_k)⁻¹),    ω = 1,  κ_k = 1 + (g_k / 24 h)²

α_s ~ N(log observed base rate of kind s, 2)
γ   ~ N(0, 1)
δ   = σ_drift · C_D u,  u ~ N(0, I),  σ_drift ~ HalfNormal(0.3)
```

- **Shrinkage.** τ_g and λ_f form a horseshoe prior (Carvalho et al. 2010): most foods have no
  effect, and the global scale lets the data pull all of them towards zero, while the heavy-tailed
  local scale lets a real trigger escape. Half-normal local scales (the first draft) shrank a
  planted ×4 trigger together with the null foods (Piironen & Vehtari 2017).
- **Slab.** The slab caps every effect scale at c = 1, as in the regularised horseshoe of Piironen
  & Vehtari (2017) with a fixed slab. A lag coefficient's prior SD is then at most about 1 on the
  log rate-ratio scale, so rate ratios between ×0.14 and ×7.4 stay plausible a priori. Without the
  slab, the heavy half-Cauchy tail let lag curves become arbitrarily steep where only a handful of
  symptoms constrain them. The sampler then diverged in nearly every simulated run, and no result
  would ever have been shown. The slab was added after the simulation exposed this (section 7.3).
- **Smooth, decaying lag curves.** P is the second-difference penalty on the spline coefficients,
  which favours smooth curves. The ridge κ_k grows with the lag centre g_k of basis function k
  (its Greville abscissa), so long lags are pulled towards zero more strongly. This follows Bayesian
  distributed-lag models (Welty et al. 2009) and the varying ridge of penalised DLNMs
  (Gasparrini et al. 2017). With the first draft's near-zero ridge (10⁻³), a flat lag curve had a
  prior SD of about 30 and generic starting points gave log densities near −10¹².
- **Kind deviations share the food's local scale.** A food that is unimportant overall is also
  unimportant for each kind. The first draft gave every deviation one absolute scale; a trigger of
  a single kind then sat in the neck of a funnel and the sampler diverged.
- **Data-dependent intercept prior.** α_s is centred on the log of the kind's observed hourly rate
  (plus 0.5 symptoms), with a wide SD of 2. Strictly this uses the data twice; with SD 2 its pull
  is weak, and simulation-based calibration (7.2) checks its effect.

`ModelPriors` holds every hyperparameter. Switches restore the first draft (constant ridge 10⁻³,
half-normal local scales, absolute deviations with scale 0.3, no slab) for comparison.

The gradient of the log density is derived by hand (no automatic differentiation) and checked
against finite differences in tests.

---

## 4. Sampler and diagnostics

The engine has its own No-U-Turn sampler in Swift (`NUTSSampler`), written after Stan's
implementation: multinomial sampling along the trajectory, the generalised U-turn criterion with
the extra checks across merged sub-trees (Hoffman & Gelman 2014; Betancourt 2017), maximum tree
depth 10. Warmup follows Stan: dual averaging of the step size towards a target acceptance
statistic (γ 0.05, t₀ 10, κ 0.75), and a diagonal mass matrix estimated in doubling windows
(initial buffer 75, terminal buffer 50, first window 25 iterations). Four chains run in parallel.
Results are bitwise identical for the same input, seed and settings, apart from timing fields.

Convergence diagnostics follow Vehtari et al. (2021): rank-normalised split-R̂ (maximum over
parameters), bulk and tail effective sample size, plus divergent transitions and tree-depth hits.
A fit passes when

- max split-R̂ < 1.01,
- min bulk ESS ≥ 400,
- no divergent transitions.

Every analysis runs three fits: all observed hours, the first half and the second half (split at
the median observed hour). The run passes only if all three fits pass. Otherwise the status is
`notConverged` and the app shows nothing from that run.

---

## 5. Run policy

Analyses run nightly as a background processing task while the phone is charging
(identifier `FabianKirschenmann.Longevity-Compass.digestion-analysis`, external power required, no
network needed, earliest start 02:00 local time), and only while tracking is active.

- Up to three attempts per night: warmup 1000 at target acceptance 0.8, then warmup 2000 at 0.9,
  then warmup 4000 at 0.95, each with 1000 draws per chain. The next attempt runs only after a
  `notConverged` result.
- If the system ends the task early, the engine is cancelled, the attempt is recorded and the task
  asks to run again (at least 15 minutes later, still on external power). Slow nights are fine.
- The seed is a 64-bit FNV-1a hash of the canonical input JSON (sorted keys, dates as seconds
  since 1970, seed field set to 0) XOR the attempt number, so the same data give the same result.
- The app keeps the last good result. When a newer run fails, it shows the last good result with
  its date.
- Settings has "Run analysis now" (foreground, with progress, cancellable) and the last run's
  diagnostics: date, duration, attempts, status, max R̂, min bulk ESS and divergences.

Timing measured on an Apple M3 Mac (unit 3, before the slab): a 180-day log with 40 foods and six
symptom kinds took about 5 minutes for attempt 1. A phone is roughly twice as slow, but that is an
estimate, not a measurement. In pilot runs (not part of results.json) the slab roughly halved the leapfrog steps
per iteration at the same target acceptance, so runs should be faster; phone timings are still
unmeasured.

---

## 6. Outputs and levels

For every feature in the fit and every posterior draw the engine computes the lag curve of the
**total** symptom rate:

```
β_f(l) = log Σ_s w_s exp(β_f,s(l)),     w_s = baseline rate of kind s / total baseline rate
```

and from it, per draw, then summarised as posterior median and 90 % interval (5 % and 95 %
quantiles):

| Output | Definition |
|---|---|
| `peakRR` | max over lags 0–96 h of exp(β(l)) |
| `averageRR` | exp(mean of β(l) over the 96 lag hours) |
| `excessPerExposure` | Σ_l μ̄₀ (exp(β(l)) − 1): extra symptoms per exposure, μ̄₀ = mean baseline hourly rate |
| `medianLagHours` | lag at which half of the positive excess has occurred |
| `probRaises` | posterior probability that Σ_l β(l) > 0 (a single number, not an interval) |
| `probPeakAbove` | posterior probability that the peak rate ratio exceeds 1.25 (reported, not used for levels) |

The same summaries exist per symptom kind; `mainKind` is the kind with the largest share of the
excess. Chart data per feature: the hourly lag curve (median and 90 % band of the rate ratio), and
per lag hour the observed exposure–symptom pairs next to the pairs expected if this food had no
effect. `confoundedWith` lists other foods whose hourly exposure series correlates with this one
at 0.9 or more. The app should say that these foods cannot be told apart.

Levels (`PatternLevel`), checked in this order:

1. **Not enough data**: fewer than 5 exposures, or fewer than 3 symptoms within 96 h after an
   exposure.
2. **Clear pattern**: `probRaises` ≥ clearProb, and in both the first-half and second-half fits
   `probRaises` ≥ halfProb.
3. **Early signal**: `probRaises` ≥ earlyProb.
4. **No link found**: at least 15 exposures, the 90 % interval of `averageRR` inside [0.8, 1.25],
   and median `peakRR` below 1.25. The peak condition was added so that a short sharp effect,
   which averages out over 96 hours, is never reported as "no link".
5. **Inconclusive**: everything else.

The thresholds earlyProb, clearProb and halfProb were calibrated by simulation (7.4): all three
are 0.80 (`Thresholds.default`).

---

## 7. Validation

There is no external reference implementation to compare against: the thing being validated is
this Swift model with this sampler, and a fit in another tool would only check that tool. The
checks below therefore test the engine directly, in layers: sampler on targets with known answers,
model gradient and density against independent formulas, model and sampler together by
simulation-based calibration, and the whole pipeline by recovering planted triggers from synthetic
users.

### 7.1 Exact-answer and unit tests

The package test suite (`swift test --package-path Packages/DigestionInsights`) checks:

- the sampler on targets with known moments: standard normal, a strongly correlated 2-D normal
  and the non-centred funnel; means and variances must match within Monte-Carlo error;
- determinism: the same seed gives bitwise identical draws;
- R̂ and ESS against hand-computed values on fixed chains;
- the analytic gradient against central finite differences in every parameter block, including
  the slab and all deviation scalings, and the log density against a direct evaluation of the
  formulas in section 3;
- B-spline bases, summaries and level rules;
- a planted ×4 trigger in a 180-day synthetic log is found (one fixed scenario, kept as a
  regression case).

### 7.2 Simulation-based calibration

Simulation-based calibration (Talts et al. 2018) checks the model and the sampler together. For
each replication, parameters are drawn from the prior, hourly symptom counts are simulated from
the model, and the engine refits them. If the inference is correct, the rank of the true value
among the posterior draws is uniform.

Setup (reduced model, production priors including the slab): 3 foods (coffee, garlic, tomato),
2 symptom kinds, 30 logged days of one synthetic meal log; 1000 replications, warmup 500 and 500
draws per chain, 4 chains, thinned to 99 draws; 11 tracked quantities (intercepts, a time-of-day
coefficient, all scale parameters, lag-curve values at 6 h and the integrated garlic curve).

Result ([results.md](../Packages/DigestionInsights/Simulation/results.md), § Simulation-based calibration): rank histograms look uniform. χ² p-values
range from 0.047 to 0.913; one of 11 lies below 0.05, about what chance gives (0.6 expected), and
none falls below the Bonferroni level 0.0045. 25 prior draws with absurd rates (above 50 symptoms
an hour) were redrawn, and 1 of the 1000 replications had a divergent transition. The
data-dependent intercept prior shows no visible bias in the intercept ranks.

### 7.3 Synthetic users

The recovery and calibration studies use synthetic users that look like plausible app users
(the generator lives in `Simulation/`; every assumption is listed in [results.md](../Packages/DigestionInsights/Simulation/results.md), § Settings):

- 2 to 4 meals a day around breakfast, lunch, an afternoon snack and dinner, an hour later at
  weekends; 15 foods with per-user tastes;
- staples (bread at most meals, coffee most mornings, milk with most coffees and in all cheese),
  a co-eaten pair (onion in 85 % of garlic meals) and a weekly rhythm (alcohol on Friday and
  Saturday evenings, fish on Fridays);
- three logging styles, careful, typical and sloppy, that differ in missed days, missed meals,
  missed symptom logs, time errors and meals logged late without fixing the time;
- ingredient evidence as in 2.5: 25 % of logged meals with a complete Open Food Facts list,
  10 % incomplete, 55 % photos (a quarter of the foods missed, 2 % chance per absent food of a
  false detection), 10 % without a profile;
- a baseline of 0.2 to 0.8 symptoms a day over 3 kinds, with a time-of-day wave;
- at most one planted trigger: one food raises one kind's rate by ×1.5, ×2 or ×4 (and ×10 in a
  small extension) inside a fast (1–4 h), medium (4–12 h) or slow (24–60 h) window after every
  real meal containing it, logged or not;
- null users without any trigger.

Each user was analysed after 14, 30, 60 and 90 logged days, and typical loggers also after 180,
with the production sampler settings (B11 attempt 1, three fits, the full convergence gate).
In total: 120 planted users, 48 null users, 688 analyses, about 3 h 35 min of compute on an
Apple M3 with 8 cores, including pilots ([results.md](../Packages/DigestionInsights/Simulation/results.md), § Compute).

Two design limits of the study matter when reading the numbers. In the main grid, trigger food
and lag window shared one index, so every fast trigger was garlic, every medium trigger a legume
and every slow trigger milk, a near-daily staple; food and window effects cannot be separated
there. Only the ×10 extension rotates foods across windows. Also, users had 15 foods and 3 kinds,
fewer than in the app.

**Convergence.** Before the slab was added (3.3), every run of a six-run pilot at the production
setting (target acceptance 0.8) had divergences, up to 73 in one fit, and even target
acceptance 0.95 left a few divergences in most runs. These pilot runs are not part of
results.json; only their compute time is listed there. With the slab, 92–100 % of analyses pass
the gate at the first attempt, depending on logging style and length; divergences occur in at
most 4 % of analyses ([results.md](../Packages/DigestionInsights/Simulation/results.md), § Convergence). The remaining failures are mostly R̂ just above 1.01.
Retries (attempts 2 and 3) were not simulated.

### 7.4 Calibration of the thresholds

The three probability thresholds were chosen on the null users, following one rule fixed before
the runs: earlyProb is the smallest value on a grid from 0.80 to 0.999 at which at most 5 % of
null analyses show any food at early signal or above; halfProb equals earlyProb (each half of
the data must show at least an early signal on its own); clearProb is the smallest grid value at
or above earlyProb at which at most 1 % of null analyses show a clear pattern. The grid starts at
0.80 on purpose: a posterior probability below 0.8 is not called a signal.

Result ([results.md](../Packages/DigestionInsights/Simulation/results.md), § Calibrated thresholds): **earlyProb = clearProb = halfProb = 0.80**. Both
targets were already met at the floor, so the floor decided all three; clear patterns differ
from early signals only through the requirement that both halves agree.

| False-positive rate (95 % Wilson interval) | early signal or clear | clear pattern |
|---|---|---|
| null analyses, pooled (208 analyses of 48 users) | 4.3 % (2.3–8.0) | 0.0 % (0.0–1.8) |
| null analyses at 90 logged days (48) | 10.4 % (4.5–22.2) | 0.0 % (0.0–7.4) |
| null users flagged in at least one of their analyses | 12.5 % (5.9–24.7) | 0.0 % (0.0–7.4) |
| other foods of users with a planted trigger | 20.0 % (16.7–23.8) | 3.3 % (2.1–5.3) |

The pooled rates meet the targets, but the study cannot resolve a 1 % rate: with 208 null
analyses, 0 hits are compatible with anything up to 1.8 %. The rate at 90 logged days is above
5 %, and a user who tracks for months sees many analyses, so the chance of seeing at least one
false early signal at some point is higher than the per-analysis rate.

The last row matters most for real users. When one food truly raises symptoms, other foods are
flagged far more often than in null users: 20 % of analyses showed some other food at early
signal or above, and 3.3 % a clear pattern. Almost all of these came from the slow milk trigger:
cheese (which contains milk), coffee (drunk with milk) and, less often, foods without any link.
A long-lasting effect of a staple raises the symptom rate for days at a time, and the model
partly attributes that to whatever else was eaten. Calibration on null users alone does not
capture this. Whether clearProb should be raised to account for it is open (section 9).

### 7.5 Recovery of planted triggers

Recovery counts how many users with a planted trigger see that food at early signal or above
([results.md](../Packages/DigestionInsights/Simulation/results.md), § Recovery of planted triggers, § Lag estimates, § Co-eaten partner).

What a rate ratio means in symptoms matters here. On the simulated baseline, one exposure adds
on average 0.02 symptoms of the trigger kind for a ×2 fast trigger, 0.06 for ×2 medium and 0.25
for ×2 slow; ×4 gives 0.06, 0.17 and 0.75, and ×10 gives 0.19, 0.50 and 2.25. Short windows
produce few extra symptoms even at large ratios.

- **Slow triggers (24–60 h, milk) are found.** With careful or typical logging a ×4 trigger
  reaches early signal or above in 3–4 of 4 users by 60–90 logged days, and a clear pattern in
  1–3 of 4. A ×2 trigger reaches early signal in about half of all users at 60 days and 10 of 12
  at 90 days, but a clear pattern rarely (1 of 12 at 90 days; 2 of 4 typical users at 180 days).
  ×1.5 is almost never found.
- **Fast (1–4 h) and medium (4–12 h) triggers are not found.** No ×1.5, ×2 or ×4 fast or medium
  trigger reached early signal at any length, including 180 logged days. In the ×10 extension
  (foods rotated), fast triggers were still never found, and medium ones in 1 of 4 users at 90
  days. The posterior peak rate ratio of these triggers stays near 1 to 1.7, against a true ×4
  or ×10. The alternative statistic `probPeakAbove` does no better.
- **Wrong "No link found".** Fast and medium triggers were often labelled `noLinkFound`, for
  example in 7–8 of 20 analyses of typical users with a ×2 or ×4 fast trigger. The peak guard in
  the level rule (section 6) does not catch this, because the estimated peak is shrunk too.
  This conflicts with the product rule that "no link found" must not be read as "safe", and it
  is listed as an open problem.
- **Delays.** For slow triggers found, the median absolute error of the estimated delay is 1.2–5 hours
  against the true 42 hours for ×2 and stronger triggers (up to 8 hours for the few ×1.5 triggers
  found), slightly too early on average. Too few
  fast or medium triggers were found to say anything about their delays.
- **Co-eaten partner.** Onion, eaten with 85 % of garlic meals, was never flagged in garlic
  users, but garlic itself was never found either, so this says nothing about separating a real
  co-eaten pair. `confoundedWith` listed onion for garlic in 1 of 160 analyses: the hourly
  correlation threshold of 0.9 is rarely reached when onion also appears without garlic.

**Headline.** With typical logging, a ×2 trigger did not reach early signal in half of the
users within 180 logged days (3 of 12 by 60 days, all of them slow triggers), and a clear
pattern in 1 of 12 at 180 days. Null false-clear rate: 0.0 % (95 % interval 0.0–1.8 %). The
user's expectation of first evidence after about 2 weeks and clear patterns after about 3 months
is **refuted** for the simulated effect sizes; it holds only for large, slow effects (×4 slow:
early signal in 1–3 of 4 users at 14 days, clear in 3 of 4 careful users by 60 days).

**Statistical power of the study.** Cells have 4 users each, so a share like 3 of 4 has a 95 %
interval of roughly 30–95 %. The tables show where the engine works and where it does not; they
do not pin down rates.

---

## 8. Limitations

- **Presence only.** Exposure says whether a food was in a meal, weighted by how sure the data
  are, not how much. A dose-dependent effect looks weaker than it is, and a small amount counts
  like a large one.
- **Taxonomy without synonyms.** Ingredient names match the taxonomy only exactly (with a
  plural-s retry). A name the taxonomy does not know is shown but never analysed, so a trigger
  hidden behind an unusual name can be missed.
- **Foods eaten together cannot be separated.** If two foods almost always appear together
  (garlic and onion in the simulation), the data cannot tell which one matters. The engine flags
  such pairs (`confoundedWith`) but does not resolve them. The same holds for a food and the
  catalogue group it belongs to.
- **Acute effects are missed.** In the simulation, triggers acting within the first 12 hours
  were not found even at ten times the baseline rate, and were often labelled "no link found"
  (7.5). Until this is fixed, the feature can only find effects that last a day or more and add
  a substantial number of symptoms.
- **A real trigger drags other foods along.** A long-lasting effect of a staple made other foods
  look like triggers in 20 % of analyses (7.4).
- **Nothing beyond 96 hours.** Effects that build up over days or weeks of eating are not
  modelled.
- **Logging bias.** The observation rule assumes every symptom on an observed day is logged. A
  user who logs only bad days, or forgets symptoms, dilutes real effects; a user who logs meals
  only on bad days creates spurious ones.
- **Meal-time accuracy.** Meals logged hours late without correcting the time smear the lag
  curve, and a short-lag effect may be missed.
- **AI misdetection.** Photo recognition misses ingredients and invents others. The evidence
  value 0.5 down-weights photo data, but it cannot fix a systematic error (for example a model
  that never sees garlic in sauces).
- **One user's data.** Nothing is pooled across users. Rare foods rarely reach enough exposures.
- **Simulation assumptions.** The synthetic users' diligence, AI error rates and food habits are
  assumptions, not measurements of real users (results.md lists them).

---

## 9. Future tests

- **Amount-based exposure.** Exposure value could scale with portion size, for example the share
  of the logged grams that a food makes up, or a log of grams. Presence-only exposure was chosen
  first because the app does not know ingredient amounts inside a meal. If presence-only results
  turn out not to be good enough, amount-based exposure is the first alternative to test, with the
  same simulation study (planted dose-dependent triggers, the same null calibration).
- **Synonyms.** The Open Food Facts source taxonomy (the `.txt` files in the Open Food Facts
  server repository) has synonym lists that the JSON export lacks. Using them would match more
  ingredient names.
- **On-device models.** On-device ingredient recognition would keep meal photos on the phone. It
  needs its own error-rate measurement before its exposures could get a higher evidence value.
- **Level rule.** `probRaises` integrates the whole 96-hour curve; `probPeakAbove` is reported next
  to it (7.5). Which one should drive the levels is open and is the user's decision.
- **Acute sensitivity.** Find out why short-lag triggers are not recovered: the lag prior
  (ridge and smoothness at short lags, the slab), meal-time errors that smear a 3-hour window,
  and the integrated statistic. Then repeat the recovery study with food and window rotated
  independently, more users per cell, the app's number of foods and kinds, and the B11 retries.
- **Spillover.** Decide whether clearProb or the level rule should account for false hits
  on foods eaten with a real trigger, and test the `noLinkFound` rule against planted acute
  triggers.

---

## 10. Code reference

- `DigestionAnalysis.run(_:progress:)`: whole analysis: design, three fits, diagnostics,
  summaries, chart data, confounding, levels. `DigestionAnalysis.fingerprint(_:)`: seed hash.
- `LagData`: observation hours, outcome counts, exposures, cross-basis.
- `LagModel`: log density and gradient; `ModelPriors`: hyperparameters, including `slabScale`.
- `NUTSSampler`, `SamplerDiagnostics`, `ConvergenceCriteria`, `Diagnostics`: sampler and checks.
- `PatternLevel.classify(...)` and `Thresholds.default`: level rules and calibrated thresholds.
- `Packages/DigestionInsights/Simulation/`: synthetic users, simulation-based calibration,
  recovery study, calibration and the `digestion-sim` command
  (`swift run -c release --package-path Packages/DigestionInsights digestion-sim report`).

---

## 11. References

- Betancourt M. (2017). A conceptual introduction to Hamiltonian Monte Carlo. arXiv:1701.02434.
- Carvalho C. M., Polson N. G., Scott J. G. (2010). The horseshoe estimator for sparse signals.
  Biometrika 97(2), 465–480.
- Gasparrini A., Armstrong B., Kenward M. G. (2010). Distributed lag non-linear models.
  Statistics in Medicine 29(21), 2224–2234.
- Gasparrini A., Scheipl F., Armstrong B., Kenward M. G. (2017). A penalized framework for
  distributed lag non-linear models. Biometrics 73(3), 938–948.
- Hoffman M. D., Gelman A. (2014). The No-U-Turn sampler. Journal of Machine Learning Research 15,
  1593–1623.
- Piironen J., Vehtari A. (2017). Sparsity information and regularization in the horseshoe and
  other shrinkage priors. Electronic Journal of Statistics 11(2), 5018–5051.
- Talts S., Betancourt M., Simpson D., Vehtari A., Gelman A. (2018). Validating Bayesian inference
  algorithms with simulation-based calibration. arXiv:1804.06788.
- Vehtari A., Gelman A., Simpson D., Carpenter B., Bürkner P.-C. (2021). Rank-normalization,
  folding, and localization: an improved R̂ for assessing convergence of MCMC. Bayesian Analysis
  16(2), 667–718.
- Welty L. J., Peng R. D., Zeger S. L., Dominici F. (2009). Bayesian distributed lag models:
  estimating effects of particulate matter air pollution on daily mortality. Biometrics 65(1),
  282–291.
- Open Food Facts: data under the Open Database Licence 1.0. <https://world.openfoodfacts.org/>
