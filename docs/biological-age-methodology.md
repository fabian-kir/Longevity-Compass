# Biological-age methodology

Version: v2 engine (Tasks 1–10).
Code reference SHA at time of writing: `68888c0`.
Reader contract: with this document, a calculator, and the user's raw
signal values you can reproduce the engine's biological-age delta by
hand to within rounding.

---

## 1. Goal & non-goals

We estimate a **biological-age delta** vs the user's chronological age
from the signals we actually have on device (Apple Watch / HealthKit,
manually-logged blood-pressure cuff readings, manually-logged bloodwork
panels, and a small set of behavior logs).

This is not:
- An epigenetic-age clock — we measure no DNA methylation.
- A mortality predictor — none of the weights are calibrated against
  survival endpoints.
- A diagnostic — out-of-range markers do not produce diagnoses, only a
  signed contribution to the delta and a UI surface.

What it is: a transparent, additive, signal-by-signal proxy. Every
year added or subtracted is traceable to a single reading times a
single per-signal weight; nothing is learned, fit, or hidden.

---

## 2. Model overview

```
biologicalAge = max(0, chronologicalAge + Σ_factor clamp(weightedMean_factor, ±yearsCap_factor))

weightedMean_factor = Σ_reading rawYearsImpact × effectiveWeight
                      ─────────────────────────────────────────
                                Σ_reading effectiveWeight

rawYearsImpact = -zScore × yearsPerSD                                 (z-scored signals)
rawYearsImpact = flatPenaltyYears (signed, no z)                       (nicotine, alcohol)

zScore = (value - mean) / sd        if signal is higherIsBetter
zScore = (mean - value) / sd        if signal is lowerIsBetter

effectiveWeight = freshnessWeight × qualityWeight
qualityWeight   = 1 if value ∈ plausibilityRange else 0
```

Sign convention: a positive z-score means "better than typical for
your age/sex". Multiplying by `-yearsPerSD` flips that into negative
years — i.e. better physiology subtracts years from chronological
age.

Layer A (downstream-suppression) zeroes the `rawYearsImpact` on
upstream-behavior readings when a fresh downstream marker is
already capturing them in the number (Section 6). Layer B and C
operate on the same readings array but only affect UI — never the
number.

---

## 3. Factor structure

The engine groups its 24 signals into 10 factors. Each factor has its
own years cap, beyond which a single noisy factor cannot drag the
estimate further.

| Factor         | Signals                                                            | yearsCap |
|----------------|--------------------------------------------------------------------|---------:|
| fitness        | vo2Max, rhr, hrv                                                   |        6 |
| glycemic       | hba1c, fastingGlucose, fastingInsulin (HOMA-IR substitution)       |        5 |
| lipids         | apoB, ldl, hdl, trigHdlRatio                                       |        5 |
| hemodynamic    | bloodPressure                                                      |        5 |
| bodyComp       | waist, weightTrend                                                 |        4 |
| inflammation   | hsCrp, homocysteine                                                |        4 |
| organ          | eGFR, alt                                                          |        3 |
| behavior       | sleep, exerciseMinutes, strengthSessions, dailySteps, nutrition    |        6 |
| nicotine       | nicotine (flat penalty)                                            |        5 |
| alcohol        | alcohol (flat penalty)                                             |        3 |

Rationale per factor:

- **fitness** — cardiorespiratory capacity is one of the single
  strongest all-cause mortality correlates in epidemiology; cap 6 lets
  fitness be a leading wins driver but not dominate.
- **glycemic** — chronic hyperglycemia is a slow, broad-impact aging
  signal; cap 5.
- **lipids** — atherogenic burden is one of the largest modifiable
  CVD inputs; cap 5.
- **hemodynamic** — BP independently drives stroke and cardiovascular
  mortality; cap 5.
- **bodyComp** — central adiposity adds risk but mostly through
  glycemic / inflammation / lipids it already drives, so cap 4 to
  avoid double-counting.
- **inflammation** — chronic low-grade inflammation has measurable
  mortality association; cap 4.
- **organ** — eGFR/ALT are slower-moving filters; cap 3.
- **behavior** — five-signal upstream cluster; cap 6 lets behavior be
  a strong wins driver when there is no downstream bloodwork.
- **nicotine** — discrete, large mortality multiplier; cap 5 matches
  the +5 active penalty.
- **alcohol** — discrete; cap 3 matches the +2 heavy + ε headroom.

---

## 4. Per-signal entries

For every signal we list: factor, direction, reference distribution
(mean, SD, sex/age handling), `yearsPerSD`, freshness rules,
plausibility range, and source. Population norms are rough midpoints,
not pinned to a specific NHANES cycle except where noted.

### Fitness

#### vo2Max
- Factor: fitness. Direction: higher is better.
- Reference: age-anchored decade table interpolated linearly.
  - Male: 20→48, 30→44, 40→40, 50→36, 60→32, 70→28 (ml/kg/min).
  - Female: 20→40, 30→37, 40→34, 50→31, 60→28, 70→25.
  - Pooled SD: 7. Source: Cooper Institute / ACSM / FRIEND registry
    tables (approximate; not pinned to a single cycle).
- yearsPerSD: 2.0 (largest single-signal weight in the engine —
  matches the strength of the VO2-mortality association in
  epidemiology).
- Freshness: linear decay. Sample age ≤ 60d → 1.0; ≥ 180d → 0.0;
  in between, `1 - (days - 60) / 120`.
- Plausibility: 5...90.

#### rhr
- Factor: fitness. Direction: lower is better.
- Reference: age-flat. Mean 65 bpm, SD 10. Source: NHANES adult means.
- yearsPerSD: 1.0.
- Freshness: 1.0 by default; halved to 0.5 if the underlying recent
  RHR series has between 1 and 13 samples (engine uses
  `restingHeartRateSeries.count < hrvMinDays = 14`, but only when
  non-empty — empty series implies HK rollup has done its own
  averaging and we trust it).
- Plausibility: 30...200.

#### hrv
- Factor: fitness. Direction: higher is better.
- Reference: age-anchored SDNN decade table interpolated linearly.
  - Male: 20→55, 30→48, 40→40, 50→34, 60→28, 70→24 (ms).
  - Female: 20→52, 30→45, 40→38, 50→32, 60→27, 70→23.
  - Pooled SD: 14. Source: Apple Watch HRV literature (Naschitz et
    al. and derivative analyses; approximate).
- yearsPerSD: 0.8.
- Freshness: fixed 0.5 today. Reason: the HealthKit sample-count API
  for HRV isn't wired through `HealthKitSnapshot` yet, so we cannot
  enforce `hrvMinDays = 14`. The 0.5 cap prevents one anomalous
  watch night from dominating the fitness factor. Listed as a known
  issue in Section 11.
- Plausibility: 1...300.

### Glycemic

#### hba1c
- Factor: glycemic. Direction: lower is better.
- Reference: mean 5.3 %, SD 0.3. Source: NHANES non-diabetic adults.
- yearsPerSD: 2.5.
- Freshness: bloodwork rule — full weight if drawn ≤ 6 months ago,
  0.5 if ≤ 12 months, 0.25 if ≤ 24 months, dropped beyond.
- Plausibility: 3.0...20.0 (%).

#### fastingGlucose
- Factor: glycemic. Direction: lower is better.
- Reference: mean 90 mg/dL, SD 8. Source: NHANES non-diabetic adults.
- yearsPerSD: 1.5.
- Freshness: bloodwork rule.
- Plausibility: 40...500.
- Note: when the lab report omits "fasting" qualifier the engine still
  matches "glucose" — acceptable for v1 since most home panels are
  morning-fasted.

#### fastingInsulin (with HOMA-IR substitution)
- Factor: glycemic. Direction: lower is better.
- Behavior: when only insulin is present, scored as raw insulin
  (mean 7 µU/mL, SD 3). When BOTH glucose and insulin are present,
  the engine computes HOMA-IR = glucose[mg/dL] × insulin[µU/mL] /
  405 and scores against HOMA-IR norms (mean 1.5, SD 0.8).
- yearsPerSD: 1.5 (carries the insulin slot in either path).
- Freshness: bloodwork rule.
- Plausibility (raw insulin): 0.5...100.
- Plausibility (HOMA-IR substitution): 0.1...50 — values outside
  collapse `qualityWeight` to 0.

### Lipids

#### apoB
- Factor: lipids. Direction: lower is better.
- Reference: mean 95 mg/dL, SD 22. Source: NHANES adult midpoint
  (approximate).
- yearsPerSD: 2.5.
- Freshness: bloodwork rule.
- Plausibility: 20...300.

#### ldl
- Factor: lipids. Direction: lower is better.
- Reference: mean 115 mg/dL, SD 28. Source: NHANES.
- yearsPerSD: 1.5.
- Freshness: bloodwork rule.
- Plausibility: 20...400.
- Note: emitted only when ApoB is absent — the engine prefers ApoB
  whenever both are available.

#### hdl
- Factor: lipids. Direction: higher is better.
- Reference (sex-anchored):
  - Male: mean 48 mg/dL, SD 12.
  - Female: mean 58 mg/dL, SD 14.
  - Source: NHANES.
- yearsPerSD: 0.8.
- Freshness: bloodwork rule.
- Plausibility: 10...150.

#### trigHdlRatio
- Factor: lipids. Direction: lower is better.
- Reference: mean 2.0 (TG/HDL in mg/dL units), SD 1.2.
- yearsPerSD: 1.2.
- Freshness: bloodwork rule.
- Plausibility: 0...50.
- Note: emitted only when both HDL and Triglycerides are parsed from
  the same panel. Bare triglycerides without HDL is intentionally
  dropped.

### Hemodynamic

#### bloodPressure
- Factor: hemodynamic. Direction: lower is better.
- Reference: systolic mean 122 mmHg, SD 12; diastolic mean 78 mmHg,
  SD 8. Source: NHANES.
- yearsPerSD: 2.0.
- Composite scoring: the engine computes a systolic z and a diastolic
  z and averages them (`z = (zSys + zDia) / 2`) so BP appears as a
  single reading in the hemodynamic factor.
- Freshness: 1.0 if any reading exists within `BP.recentWindowDays`
  (14 days); otherwise the signal is dropped.
- Plausibility: systolic 60...260; diastolic 30...200 enforced
  separately. Either out → `qualityWeight = 0`.

### Inflammation

#### hsCrp
- Factor: inflammation. Direction: lower is better.
- Distribution handling: hs-CRP is log-normal. The engine takes
  `log10(raw mg/L)` and scores it against a log-space reference:
  mean 0.0 (i.e. geometric mean 1.0 mg/L), SD 0.45.
- Source: Ridker / JUPITER population geometric means.
- yearsPerSD: 1.5.
- Freshness: bloodwork rule.
- Plausibility: 0.05...50 (compared against the *raw* mg/L value, not
  the log-transformed one).
- Note: values ≤ 0 are dropped pre-log.

#### homocysteine
- Factor: inflammation. Direction: lower is better.
- Reference: mean 9 µmol/L, SD 3. Source: NHANES adult midpoint.
- yearsPerSD: 0.6.
- Freshness: bloodwork rule.
- Plausibility: 3...100.

### Organ

#### eGFR
- Factor: organ. Direction: higher is better.
- Reference: age-anchored decade table.
  - 20→105, 30→100, 40→95, 50→90, 60→85, 70→78 (mL/min/1.73m²).
  - SD: 15. Source: KDIGO 2024 eGFR references.
- yearsPerSD: 1.0.
- Freshness: bloodwork rule.
- Plausibility: 5...200.

#### alt
- Factor: organ. Direction: lower is better.
- Reference (sex-anchored):
  - Male: mean 27 U/L, SD 11.
  - Female: mean 22 U/L, SD 9.
  - Source: NHANES.
- yearsPerSD: 0.6.
- Freshness: bloodwork rule.
- Plausibility: 1...500.

### Body composition

#### waist
- Factor: bodyComp. Direction: lower is better.
- Reference (sex-anchored):
  - Male: mean 94 cm, SD 12.
  - Female: mean 80 cm, SD 11.
  - Source: NHANES.
- yearsPerSD: 1.5.
- Freshness: 1.0 if the latest waist manual entry is within
  `BodyComp.lookbackDays = 90` days; otherwise the signal is dropped.
- Plausibility: 40...200.

#### weightTrend
- Factor: bodyComp. Direction: lower is better.
- Reference: mean 0 % (most adults are weight-stable), SD 2.5 %
  per-90-days.
- yearsPerSD: 0.5.
- Construction: signed percent change between the latest body-mass
  sample and the earliest sample ≤ 90 days ago (or the earliest
  sample in the series if none predates the 90-day cutoff). Positive
  values mean weight gain.
- Freshness: 1.0 if ≥ `weightSeriesMinPoints = 6` samples in the
  90-day window; otherwise dropped.
- Plausibility: -50...50 %.

### Behavior

#### sleep
- Factor: behavior. Direction: higher is better.
- Reference: mean 7.5 h/night, SD 1.0. Source: CDC adult averages.
- yearsPerSD: 1.0.
- Freshness: 1.0 (HealthKit 7-day rolling average; the snapshot
  upstream gates staleness).
- Plausibility: 0...16.

#### exerciseMinutes
- Factor: behavior. Direction: higher is better.
- Reference: mean 150 min/week (the WHO / ACSM guideline anchor),
  SD 120 min/week.
- yearsPerSD: 1.0.
- Freshness: 1.0.
- Plausibility: 0...3000.

#### strengthSessions
- Factor: behavior. Direction: higher is better.
- Reference: mean 1.0/week, SD 1.0. Most adults sit around 1
  strength session per week.
- yearsPerSD: 0.6.
- Freshness: 1.0.
- Plausibility: 0...20 sessions/week.

#### dailySteps
- Factor: behavior. Direction: higher is better.
- Reference: mean 6500 steps/day, SD 3000. Source: large
  smartphone/wearable population studies (approximate).
- yearsPerSD: 0.4.
- Freshness: 1.0.
- Plausibility: 0...100 000.
- Note: emitted only when Apple Exercise Time is missing, to avoid
  double-counting cardio behavior within the same factor.

#### nutrition
- Factor: behavior. Direction: higher is better.
- Construction: a composite "favorable minus unfavorable" bucket
  score derived from the nutrition digest. Favorable buckets at or
  above their `.ok` status: plantVariety, leafyGreenDays, legumeDays,
  fermentedDays. Unfavorable buckets at `.high` or `.veryHigh`:
  ultraProcessedMeals, processedMeatMeals, friedMeals. Score = good
  count − bad count.
- Reference: mean 0, SD 1 (placeholder distribution until a real
  nutrition score arrives — explicitly noted in code).
- yearsPerSD: 0.5.
- Freshness: 1.0 if any rollups exist at all (`(good + bad) > 0`).
- Plausibility: -100...100.

### Flat-penalty signals (nicotine, alcohol)

These bypass the z-score path and contribute an integer-ish years
penalty directly. They are immune to Layer A suppression.

#### nicotine
- Factor: nicotine. Look-back: 60 days
  (`BioAge.V2.nicotineWindowDays`).
- Decision: if ANY nicotine entry in the last 60 days has
  `booleanValue == true`, contribute **+5 years** (active use).
  Otherwise, if any nicotine entries exist at all in the window
  (i.e. user logged a "no nicotine" entry), contribute **−1 year**
  (documented clean log reward).
- No entries in the window → signal omitted (no contribution).
- yearsPerSD: n/a (flat penalty); cap on factor is 5.

#### alcohol
- Factor: alcohol. Look-back: 14 days
  (`BioAge.V2.alcoholWindowDays`).
- Counts within window:
  - `heavy` ≥ 2 → contribute **+2 years** (heavy pattern).
  - else `heavy + light` ≥ 5 → contribute **+1 year** (frequent
    pattern).
  - else `none` ≥ 7 and `(heavy + light) == 0` → contribute
    **−0.5 years** (documented alcohol-free window).
  - else → signal omitted (insufficient pattern signal either way).
- yearsPerSD: n/a; cap on factor is 3.

---

## 5. Worked example — Profile A (Elite endurance 40M)

Profile A from `BioAgeProfileTests.swift`. The harness asserts the
delta lands in `[-12.0, -3.0]`. The exact engine-observed delta is
**−8.25 yr**.

Inputs (run at `now`):
- DOB 40 years ago → chronologicalAge = 40.0.
- Sex = male.
- VO2 max 55 ml/kg/min, 45 days old.
- RHR 28d avg = 48 bpm, empty recent-series array.
- HRV 28d avg = 65 ms.
- Sleep 7d avg = 8.0 h.
- Exercise minutes/week = 360. Strength sessions last 7d = 3.
- Body mass: 7 weight samples of 75 kg spaced across the 90d window.
- Waist (manual, 7d old) = 82 cm.
- No nicotine entries. No alcohol entries. No nutrition digest.
- Bloodwork panel, 30 days old:
  - HbA1c 5.0 %, ApoB 75 mg/dL, hs-CRP 0.6 mg/L,
    HDL-C 60 mg/dL, Triglycerides 80 mg/dL, eGFR 100 mL/min.

Per-signal computation (40M norms, ml/kg/min for VO2 etc.):

| Signal         | value | mean   | sd   | direction | z      | yps | rawYears | fresh | quality | effW |
|----------------|------:|-------:|-----:|-----------|-------:|----:|---------:|------:|--------:|-----:|
| vo2Max         |  55   |  40    |  7   | higher    |  2.143 | 2.0 |  -4.286  | 1.00  | 1       | 1.00 |
| rhr            |  48   |  65    | 10   | lower     |  1.700 | 1.0 |  -1.700  | 1.00  | 1       | 1.00 |
| hrv            |  65   |  40    | 14   | higher    |  1.786 | 0.8 |  -1.429  | 0.50  | 1       | 0.50 |
| hba1c          |  5.0  |  5.3   |  0.3 | lower     |  1.000 | 2.5 |  -2.500  | 1.00  | 1       | 1.00 |
| apoB           |  75   |  95    | 22   | lower     |  0.909 | 2.5 |  -2.273  | 1.00  | 1       | 1.00 |
| hdl            |  60   |  48    | 12   | higher    |  1.000 | 0.8 |  -0.800  | 1.00  | 1       | 1.00 |
| trigHdlRatio   |  1.333|  2.0   |  1.2 | lower     |  0.556 | 1.2 |  -0.667  | 1.00  | 1       | 1.00 |
| hsCrp (log10)  | -0.222|  0.0   |  0.45| lower     |  0.494 | 1.5 |  -0.741  | 1.00  | 1       | 1.00 |
| eGFR           | 100   |  95    | 15   | higher    |  0.333 | 1.0 |  -0.333  | 1.00  | 1       | 1.00 |
| waist          |  82   |  94    | 12   | lower     |  1.000 | 1.5 |  -1.500  | 1.00  | 1       | 1.00 |
| weightTrend    |  0.0  |  0.0   |  2.5 | lower     |  0.000 | 0.5 |   0.000  | 1.00  | 1       | 1.00 |
| sleep          |  8.0  |  7.5   |  1.0 | higher    |  0.500 | 1.0 |  -0.500  | 1.00  | 1       | 1.00 |
| exerciseMinutes| 360   | 150    |120   | higher    |  1.750 | 1.0 |  -1.750  | 1.00  | 1       | 1.00 |
| strengthSess.  |   3   |   1.0  |  1.0 | higher    |  2.000 | 0.6 |  -1.200  | 1.00  | 1       | 1.00 |

TG:HDL ratio = 80 / 60 = 1.333. hs-CRP `log10(0.6) = -0.2218`.

Layer A suppression. Downstream signals with `effectiveWeight` strictly
> 0.5 include vo2Max, rhr, hba1c, apoB, hdl, trigHdlRatio, hsCrp,
eGFR. HRV's effW is exactly 0.5 — strict inequality means it does
NOT by itself suppress. But the others do. So:

- `sleep` targets {glycemic, inflammation, fitness} → hba1c, hsCrp,
  vo2Max, rhr are all present at >0.5 → **suppressed**, rawYears → 0.
- `exerciseMinutes` targets {fitness} → vo2Max, rhr present at >0.5
  → **suppressed**, rawYears → 0.
- `strengthSessions` targets {fitness} → **suppressed**, rawYears → 0.
- No nutrition reading (digest = nil).
- No dailySteps (exerciseMinutes was present).

Factor aggregation (weighted mean of `rawYearsImpact` by
`effectiveWeight`, then ±cap):

| Factor       | live readings (rawYears × effW)                                   | Σ(rawYears·effW) | Σ effW | weighted | cap | clamped |
|--------------|-------------------------------------------------------------------|-----------------:|-------:|---------:|----:|--------:|
| fitness      | vo2: -4.286·1 + rhr: -1.700·1 + hrv: -1.429·0.5                   | -6.700           |  2.50  |  -2.680  |  6  | -2.680  |
| glycemic     | hba1c: -2.500·1                                                   | -2.500           |  1.00  |  -2.500  |  5  | -2.500  |
| lipids       | apoB: -2.273·1 + hdl: -0.800·1 + tgHdl: -0.667·1                  | -3.740           |  3.00  |  -1.247  |  5  | -1.247  |
| inflammation | hsCrp: -0.741·1                                                   | -0.741           |  1.00  |  -0.741  |  4  | -0.741  |
| organ        | eGFR: -0.333·1                                                    | -0.333           |  1.00  |  -0.333  |  3  | -0.333  |
| bodyComp     | waist: -1.500·1 + weightTrend: 0·1                                | -1.500           |  2.00  |  -0.750  |  4  | -0.750  |
| hemodynamic  | (no BP data)                                                       | —                |   0    |    —     |  5  |   0     |
| behavior     | all 3 readings suppressed (live = ∅)                              | —                |   0    |    —     |  6  |   0     |
| nicotine     | (no entries)                                                       | —                |   0    |    —     |  5  |   0     |
| alcohol      | (no entries)                                                       | —                |   0    |    —     |  3  |   0     |

Total years delta: `-2.680 + -2.500 + -1.247 + -0.741 + -0.333 + -0.750 = -8.251`.

`biologicalAge = max(0, 40.0 + (-8.251)) = 31.75`.

Engine reports delta **−8.25 yr**. Harness expected range [-12.0,
-3.0] — observed lands well inside.

Confidence: sum of effective weight across non-suppressed readings =
1 + 1 + 0.5 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 = 10.5, divided by
`targetCoverage = 10`, clamped to [0, 1] → **1.0**.

Top lever: every behavior candidate has z > 0 (positive z = better
than typical). The `topLever` filter requires `zScore < 0`, so the
candidate set is empty → `topLever = nil`. Matches the harness
assertion.

---

## 6. Layer A — downstream suppression

Rule: a behavior reading's `rawYearsImpact` is set to 0 when ANY
downstream signal in any of the behavior's target factors is present
in the readings array with `effectiveWeight > 0.5` (strict
inequality). The reading remains in the array with
`suppressedByDownstream = true` so Layers B and C still see it.

Thresholds:
- `layerASuppressionMinWeight = 0.5` (strict greater-than).
- HRV with its current fixed freshness 0.5 cannot by itself suppress
  (strict inequality). Once Task-4 sample-count wiring lands and HRV
  can earn freshness 1.0, it will start suppressing fitness-targeted
  behaviors on its own.

Downstream-signal map per factor:

| Factor       | Downstream signals                          |
|--------------|---------------------------------------------|
| glycemic     | hba1c, fastingGlucose, fastingInsulin       |
| fitness      | vo2Max, rhr, hrv                            |
| inflammation | hsCrp, homocysteine                         |
| lipids       | apoB, ldl, hdl, trigHdlRatio                |

Behavior-to-target-factors map:

| Behavior signal   | Targets factors                       |
|-------------------|---------------------------------------|
| sleep             | glycemic, inflammation, fitness       |
| nutrition         | glycemic, lipids, inflammation        |
| exerciseMinutes   | fitness                               |
| strengthSessions  | fitness                               |
| dailySteps        | fitness                               |

Exemptions:
- **nicotine, alcohol** — flat-penalty signals capture acute toxicity
  bloodwork doesn't reflect on the same timescale, and there's no
  z-scored insulin slot that represents nicotine exposure. Always
  contribute.
- **waist, weightTrend** — these are themselves downstream signals
  (body composition is a result of behavior), not upstream
  behaviors; they are never keys in
  `layerATargetFactorsByBehaviorSignal`.

What "zeroing" means in practice:
- `reading.rawYearsImpact ← 0` so the reading does not affect the
  factor weighted mean.
- `reading.suppressedByDownstream ← true`.
- The reading is preserved in `BioAgeEstimate.readings` so that
  Layer B drivers (and the missing-input UI) can still surface it.
- During factor aggregation the engine filters out
  `suppressedByDownstream == true` items so neither their
  `rawYearsImpact` nor their `effectiveWeight` participates in the
  weighted mean. Suppressed readings also do not contribute to the
  confidence sum.

Single-pass correctness: downstream signals are never themselves
behaviors (no signal appears as both a behavior key and a downstream
value), so one suppression pass is exhaustive.

---

## 7. Layer B — drivers map

Each downstream marker has a hand-curated list of upstream-behavior
drivers ordered by typical mechanistic importance. This list is the
candidate set; the personalized filter ranks it by the user's actual
weakness on each candidate.

| Downstream      | Ordered upstream drivers                                  |
|-----------------|-----------------------------------------------------------|
| hba1c           | nutrition, exerciseMinutes, weightTrend, sleep            |
| fastingGlucose  | nutrition, exerciseMinutes, weightTrend, sleep            |
| fastingInsulin  | nutrition, exerciseMinutes, weightTrend, sleep            |
| apoB            | nutrition, weightTrend, exerciseMinutes                   |
| ldl             | nutrition, weightTrend, exerciseMinutes                   |
| hdl             | exerciseMinutes, nutrition, alcohol                       |
| trigHdlRatio    | nutrition, exerciseMinutes, alcohol                       |
| bloodPressure   | sleep, alcohol, weightTrend, nutrition                    |
| hsCrp           | nutrition, alcohol, sleep, weightTrend                    |
| homocysteine    | nutrition                                                 |
| vo2Max          | exerciseMinutes, strengthSessions, sleep                  |
| rhr             | exerciseMinutes, sleep                                    |
| hrv             | sleep, exerciseMinutes, alcohol                           |
| eGFR            | bloodPressure, nutrition                                  |
| alt             | nutrition, alcohol, weightTrend                           |
| waist           | nutrition, exerciseMinutes, alcohol                       |
| weightTrend     | nutrition, exerciseMinutes                                |

Mechanistic one-liners (verbatim intent from code comments):

- **HbA1c** reflects 90-day glucose; carb quality + post-meal activity + visceral fat drive it; sleep modulates insulin sensitivity.
- **Fasting glucose** tracks hepatic insulin sensitivity; nutrition + activity + adiposity dominate; sleep debt raises it.
- **Fasting insulin / HOMA-IR** is driven by visceral fat + diet + activity; poor sleep worsens insulin resistance.
- **ApoB** responds to dietary saturated fat + fiber, body fat, and aerobic activity.
- **LDL-C** drivers mirror ApoB: diet composition first, adiposity, then aerobic exercise.
- **HDL** is most responsive to aerobic exercise, then diet quality; alcohol modestly raises but is not a lever to push.
- **TG:HDL ratio** is the canonical metabolic-syndrome marker — refined carbs, exercise, alcohol drive it.
- **Blood pressure**: sleep apnea + alcohol + visceral fat + sodium/diet are the main modifiable drivers.
- **hs-CRP** is driven by adipose tissue + diet pattern + alcohol; short sleep raises it independently.
- **Homocysteine** is primarily a B-vitamin (folate / B12 / B6) story — diet is the lever.
- **VO2 max** is built by aerobic volume + intensity, supported by strength work; sleep gates recovery.
- **Resting heart rate** falls with aerobic training and adequate sleep.
- **HRV** is suppressed by short / disturbed sleep and alcohol; aerobic fitness raises baseline.
- **eGFR** decline is accelerated by hypertension and high-protein / high-sodium diets.
- **ALT** elevation tracks NAFLD — driven by diet (fructose / refined carbs), alcohol, and visceral adiposity.
- **Waist** is set by energy balance + diet quality + activity; alcohol calories add visceral fat.
- **Weight trend** (90d % change) is energy balance: diet quality + activity dominate.

Personalized filter (`upstreamDrivers(for:limit:)`):
1. Look up the candidate set for the downstream signal.
2. Keep only candidates currently in the user's readings array.
3. Keep only those with `rawYearsImpact > layerBWeaknessYearsThreshold = 0.25`
   (i.e. the user is at least 0.25y worse than typical on that
   behavior — note this uses the *post-Layer-A* `rawYearsImpact`).
4. Sort descending by `rawYearsImpact`. Truncate to `limit` (default 3).
5. Returns `[]` when nothing clears the bar.

Effect on the number: **zero**. Layer B is purely a UI surface — the
detail sheet uses it to render "common drivers of your high X" plus
"your strongest lever among them is Y".

---

## 8. Layer C — top lever

Ranks the user's strongest upstream-behavior opportunity. Algorithm:

1. **Candidate set**: readings whose signal is one of `sleep,
   nutrition, exerciseMinutes, strengthSessions, dailySteps` (the
   keys of the Layer A behavior map). Nicotine and alcohol are
   excluded — they are flat penalties, not z-scored, and don't
   define a behavior-as-a-lever in this sense.
2. **Weakness filter**: keep only readings with `zScore < 0` (worse
   than typical).
3. **Potential**: compute `potential = |zScore × yearsPerSD|` —
   importantly, this is the **un-suppressed** magnitude, not
   `rawYearsImpact`. A behavior that Layer A has already zeroed
   because of a fresh downstream marker can still rank as the top
   lever (this is the intended decoupling: "scored in the number"
   vs "user's strongest opportunity").
4. **Threshold**: discard candidates with `potential ≤ 0.25`
   (matches `layerBWeaknessYearsThreshold`). Without this gate a
   user whose behaviors all sit at z ≈ −0.01 would still get a
   meaningless top-lever recommendation.
5. **Sort**: primary key `potential` descending. Tie-break: count of
   the user's failing downstream markers (any downstream with
   `rawYearsImpact > 0.25`) that list this behavior in their Layer
   B drivers — more multi-causes wins. Final stable tie-break:
   index in the canonical behavior order
   `[sleep, nutrition, exerciseMinutes, strengthSessions,
   dailySteps]` (earlier wins).
6. Return the top-ranked reading, or `nil` if no candidate survived.

Profile A test: candidates exist, but every behavior has z > 0 (the
user is above typical on sleep, exercise, strength). The `zScore < 0`
filter empties the set → `topLever = nil`. The harness explicitly
permits either nil or low-magnitude (<1y).

---

## 9. Confidence

```
confidence = clamp( Σ readings effectiveWeight / targetCoverage, 0, 1 )
targetCoverage = 10
```

Suppressed readings (`suppressedByDownstream == true`) contribute 0 to
this sum.

`effectiveWeight = freshnessWeight × qualityWeight` per reading.

`qualityWeight ∈ {0, 1}`: a reading whose value falls outside its
`plausibilityRange` collapses to 0 — keeps a lab transcription error
from poisoning the weighted mean AND from inflating coverage.

Freshness recap (full per-signal rules in Section 4):
- vo2Max: linear decay between 60d (full) and 180d (zero).
- rhr: 1.0 unless underlying recent series has 1–13 samples → 0.5.
- hrv: fixed 0.5 today (Task-4 follow-up to read sample count).
- All bloodwork-derived signals (hba1c, fastingGlucose,
  fastingInsulin/HOMA-IR, apoB, ldl, hdl, trigHdlRatio, hsCrp,
  homocysteine, eGFR, alt): 1.0 within 6 months, 0.5 within 12,
  0.25 within 24, dropped beyond.
- bloodPressure: 1.0 if any reading within 14 days, else dropped.
- waist: 1.0 if within 90 days, else dropped.
- weightTrend: 1.0 if ≥ 6 samples in the 90-day window.
- sleep, exerciseMinutes, strengthSessions, dailySteps, nutrition:
  1.0 if data is present at all.
- nicotine, alcohol: 1.0 (flat penalty path always has
  effectiveWeight = 1).

`targetCoverage = 10` reflects roughly ten of the legacy "primary"
signals (VO2, RHR, HRV, HbA1c, ApoB or LDL, BP, waist or weight,
sleep, exercise, one inflammation marker) at full effective weight.
The constant is intentionally not derived — it's the bar at which
the engine has "enough" signal to call the estimate high-confidence.

---

## 10. Trend

A 90-day directional indicator derived from a small subset of signals
that have a clean "then vs now" pair available in the snapshot.

Per-signal trend contributions (`yearsPer90Days`):

- **VO2 max**: requires both `latestVO2Max` and a non-empty
  `vo2MaxSeries`. The engine takes the most recent sample older than
  the 90-day cutoff as "then" and the latest as "now", computes the
  same z-score-driven years for each (using current age and sex
  norms), and appends `(-zNow · yps) - (-zThen · yps)`.
- **RHR**: requires both `restingHeartRateAverage28d` (now) and
  `restingHeartRateAverage90d` (then). Same z-score-driven years
  delta.
- **Body mass drift**: requires the latest body-mass sample and a
  sample at or before the 90-day cutoff; the percent change must
  exceed `BodyComp.weightChangePercentBorderline = 3 %` in absolute
  value (smaller drifts are noise). The single z-score-driven years
  impact of the drift is appended; the "then" baseline is treated
  as 0-drift (z = 0), so the contribution is just the drift's own
  years impact.

`yearsPer90Days = sum of the per-signal deltas` if any are present;
otherwise nil.

Mapping to `TrendDirection`:
```
t = yearsPer90Days
t ≤ trendImprovingThreshold (-0.3)  → .improving
t ≥ trendWorseningThreshold (+0.3)  → .worsening
otherwise                            → .stable
nil                                  → .unknown
```

The thresholds are intentionally outside the day-to-day jitter zone
of any single signal — a trend has to be measurable across both watch
signals AND/OR a weight drift before we surface it as a direction.

---

## 11. Limitations & known issues

- **Not an epigenetic clock.** We have no DNA-methylation input. This
  is a behavioral / biomarker proxy.
- **Population norms are rough.** Most means and SDs are listed as
  "NHANES adult midpoint" or "approximate" — they are not pinned to a
  specific NHANES cycle, and not all are from a single cycle. The
  comment block in `BioAge.V2` is explicit about this.
- **No personal calibration.** The engine doesn't learn from the
  user. Two users with identical signals get identical deltas.
- **HRV freshness fixed at 0.5.** The HealthKit sample-count surface
  for HRV is not yet wired through `HealthKitSnapshot`. Until that
  lands, HRV gets a permanent half weight to keep one anomalous
  watch night from dominating fitness. This also means HRV alone
  never triggers Layer A suppression (its effW = 0.5 fails the
  strict-greater-than test).
- **TG-without-HDL is dropped.** Bare triglycerides are noisier than
  the ratio and we don't want to double-count when HDL arrives in
  the next panel.
- **LDL is suppressed by ApoB.** When both are present in the panel
  only ApoB is scored. We do not blend.
- **Non-fasting glucose can sneak in.** The "glucose" needle matches
  whether or not the panel labels it as fasting. Acceptable for v1
  given most home-panel glucose draws are morning-fasted.
- **No genetics, no sex hormones, no medications, no chronic-disease
  modifiers.** A user on a statin and a user without one but with
  identical lipids look identical to the engine. We do not adjust.
- **No mortality calibration.** The yearsPerSD weights are calibrated
  by hand against the magnitude of published associations, not
  against survival endpoints.
- **`targetCoverage = 10` is a heuristic.** A user with 11 fully-fresh
  signals registers confidence 1.0 just as a user with 10 does; the
  curve doesn't keep climbing.
- **Empty RHR series is treated as fresh.** When
  `restingHeartRateSeries == []` we trust the rollup average (HK has
  done its own averaging); only a non-empty but short series triggers
  the 0.5 freshness halving. This is by design but worth flagging.

---

## 12. Cross-reference to the code

- **Engine logic**: `Longevity Compass/Services/BiologicalAgeEngine.swift`.
  - `evaluate(...)`: orchestrator that gathers readings, applies
    Layer A, computes factor weighted means + caps, sums the delta,
    computes confidence and trend.
  - Per-signal builders: `vo2MaxReading`, `rhrReading`, …,
    `nicotineReading`, `alcoholReading`.
  - `makeReading` / `makeFlatPenaltyReading`: the only call sites
    that construct `BioInputReading`s.
  - `applyLayerASuppression`, `layerADownstreamSignalsByFactor`,
    `layerATargetFactorsByBehaviorSignal`: Layer A.
  - `layerBDriversByDownstream` + `BioAgeEstimate.upstreamDrivers`:
    Layer B.
  - `BioAgeEstimate.topLever`: Layer C.
  - `compute90DayTrend`: trend.
- **Reference constants**: `Longevity Compass/Config/HealthThresholds.swift`,
  `enum BioAge.V2`. Every mean, SD, decade norm, freshness window,
  factor cap (via `BioFactor.yearsCap`), yearsPerSD (via
  `BioSignal.yearsPerSD`), and flat-penalty value listed here lives
  inside that block. The block carries a comment pointing readers to
  this document — **when adjusting any number, edit both files in
  the same commit**.
- **Sanity harness**: `Longevity Compass/Services/BioAgeProfileTests.swift`.
  Four representative profiles; Profile A is the worked example
  above. Harness is `#if DEBUG` only.
- **UI strings**: `BioAgePresentation.swift` (referenced by the
  detail sheet, z-bar chips, top-lever CTA, and missing-input CTA
  from Task 8).

---

## 13. References

The numeric anchors above are drawn from the following population
sources. Where the precise cycle or paper is not pinned in code, the
entry is marked "approximate".

- NHANES (National Health and Nutrition Examination Survey),
  multiple cycles. Source for adult means and SDs of: HbA1c, fasting
  glucose, ApoB, LDL-C, HDL-C (sex-split), systolic and diastolic
  BP, hsCRP plausibility floor, homocysteine, ALT (sex-split),
  waist (sex-split), resting heart rate. <https://www.cdc.gov/nchs/nhanes/>
- **Cooper Institute / ACSM VO2 max reference tables**, sex × decade
  midpoints; pooled SD ≈ 7 ml/kg/min. Approximate — not pinned to a
  single edition. <https://www.cooperinstitute.org/> ; ACSM's
  Guidelines for Exercise Testing and Prescription.
- **FRIEND registry** (Fitness Registry and the Importance of
  Exercise National Database) — cross-checks the VO2 max norms.
  Kaminsky et al., Mayo Clinic Proceedings.
- **KDIGO 2024 Clinical Practice Guideline for the Evaluation and
  Management of CKD** — eGFR age-anchored decade midpoints; pooled
  SD ≈ 15 mL/min/1.73m². <https://kdigo.org/guidelines/ckd-evaluation-and-management/>
- **Ridker / JUPITER** cohort — hsCRP log-normal geometric mean and
  SD (log10 mean ≈ 0.0, SD ≈ 0.45).
- **Apple Watch HRV (SDNN) literature** — Naschitz et al. and
  derivative analyses of the Apple Heart Study. Decade midpoints
  approximate, not pinned to a single paper.
- **CDC adult sleep averages** — mean 7.5 h/night, SD 1.0.
  <https://www.cdc.gov/sleep/>
- **WHO 2020 Guidelines on Physical Activity** — 150 min/week
  moderate-intensity exercise as the population anchor (used as the
  exerciseMinutes mean). <https://www.who.int/publications/i/item/9789240015128>
- **Large smartphone/wearable population studies** (e.g. Althoff et
  al., Nature 2017) — daily-steps mean and SD. Approximate; not
  pinned.
- **Clinical bio-age literature** — the +5 / -1 nicotine flat
  penalties and the +2 / +1 / -0.5 alcohol bands match orders of
  magnitude reported in popular bio-age clocks (e.g. PhenoAge-style
  behavioral overlays); the specific year values are calibrated by
  hand against the factor caps.

Where a number above carries no pinned citation in code, it should
be treated as a calibrated population estimate, not an experimentally
validated constant.
