# Portfolio-Hardening Plan

Status: draft, ready to execute.
Owner: Fabian Kirschenmann.
Target outcome: convert Longevity Compass from "helpful personal project" into a credible hiring signal on a public GitHub profile.

---

## Main goal

Land a first full-time job in Germany after the B.Sc. in Engineering Cybernetics by making the GitHub project legible to two reader types within ~30 seconds:

1. **Recruiter / non-technical screener** — sees a clean README, a short demo (GIF/video), a CI badge, and a one-line pitch that frames the project as engineering, not "an iOS app."
2. **Technical hiring manager** — opens the methodology doc and the bio-age engine, finds a multi-sensor estimator with explicit weighting and noise handling, and recognises the Engineering Cybernetics fingerprint immediately.

**Positioning** — the headline is *not* "I built a health-tracking iOS app." It is:

> *Multi-sensor biological-age estimator with transparent, hand-reproducible methodology — 24 HealthKit signals fused into a 10-factor model, plus a hybrid local/cloud AI pipeline for nutrition capture.*

Three signals to convey: (a) I've done AI in a non-trivial way, (b) I can ship a substantial project solo with modern tooling, (c) the engineering domain — sensor fusion under noise — fits cybernetics, not "frontend dev."

Non-goals: do **not** add a backend, auth, Watch app, Android port, or further feature breadth. The current surface is already broad enough; further breadth dilutes the signal.

---

## Where the project stands today

- **62 Swift files, ~14k LOC.** Clean decomposition: `Views/`, `Models/`, `Services/`, `Config/`.
- **`BiologicalAgeEngine`** — 24 signals → 10 factors → years delta, z-scored, freshness-weighted. Fully documented and hand-reproducible (`docs/biological-age-methodology.md`).
- **HealthKit** — steps, active energy, exercise minutes, RHR, HRV (SDNN), body mass, waist, VO2max, BP, sleep, workouts.
- **Hybrid AI nutrition pipeline** — local Vision barcode detect → OpenRouter (Claude Sonnet 4.6) vision fallback. Category-fingerprint schema, no false gram precision. Offline queue with `NWPathMonitor`.
- **Production touches** — Keychain-stored API keys, deep-link navigation between views, accessibility labels, `LocalizedError` enums, JSON export with DTOs, SwiftData lightweight migration.
- **Tests** — DEBUG-only profile harness (`BioAgeProfileTests.swift`, 4 synthetic profiles). Not wired as an XCTest target; no CI.

Both nutrition redesign phases are shipped. No half-finished feature is currently blocking a "complete" claim.

---

## Plan — four work items, in execution order

### 1. Scope-closure audit (was item #4 in the brainstorm)

**Goal:** be able to honestly say "this project is feature-complete for v1" in the README. No half-finished surfaces, no dead code, no TODO debt that a reader will trip over.

**Why first:** cheap, removes risk of later items revealing scope gaps, and produces the canonical "what's in v1" list that the README will quote.

**Tasks:**

- Walk every top-level view in `Views/` and confirm each one has a finished happy path and a sensible empty/error state. Flag anything that opens to a placeholder.
- `grep -rn "TODO\|FIXME\|XXX"` the codebase. For each hit: fix, delete, or convert to a tracked GitHub issue (don't leave TODOs as the public face of the repo).
- Confirm Nutrition Phase 1 + Phase 2 are both shipped (they are — `MealCategory`, `MealFingerprint`, `fingerprintJSON` all present). Remove any dead text-description AI path remnants if any survive.
- Audit `Config/HealthThresholds.swift` for orphaned constants from old experiments.
- Produce a short `docs/scope.md` (one page) listing every user-facing feature in v1, by tab/screen. This becomes the README's feature list verbatim.

**Done when:** zero TODO/FIXME in committed code, every view has a finished happy path, `docs/scope.md` exists.

**Estimated effort:** 2–4 hours.

---

### 2. Cybernetics framing — make the engineering visible (was item #2)

**Goal:** turn the bio-age engine from "a health score" into a visible multi-sensor estimator with explicit signal-processing choices. This is the single highest-leverage change for the technical-reader audience.

**Why second:** with scope closed, this is the work that actually moves the needle on positioning. It also gives the methodology doc and README richer material to point at.

**Two sub-tasks — do one minimum, both ideal:**

**2a. Explicit noise handling on HRV (and ideally RHR).**
HRV is famously noisy day-to-day. Add a real smoother and document it:

- Implement an **exponentially-weighted moving average** (EWMA, α tuned to ~7-day effective half-life) over the raw HRV signal before it enters the z-score stage. Optionally a 1-D Kalman filter framing if you want stronger cybernetics vocabulary — but EWMA with a derivation is honest and sufficient.
- Surface "smoothed HRV vs. raw" somewhere lightweight in the UI (a sparkline behind the bio-age detail sheet's HRV row, or just a footnote "uses 7-day EWMA-smoothed HRV").
- Add a short section to `docs/biological-age-methodology.md` titled *Noise handling* explaining the smoother, its parameter, and why it matters (HealthKit HRV SDNN is single-night noise; effect on bio-age delta without smoothing).

**2b. Sensitivity readout in the bio-age detail sheet.**
The factor model already supports this — surface it:

- For each factor (or the top three levers), compute `∂(bioAgeDelta)/∂(signal)` numerically by perturbing the input ±10% and re-running `evaluate()`. Show it as "improving HRV by 10% would move your bio-age delta by −0.4 years."
- This is a textbook cybernetics output (linearised system sensitivity) presented as a user-friendly number.
- One screenshot of this view goes straight into the README.

**Done when:** at least one of (2a, 2b) is shipped and visible in the UI; the methodology doc reflects the change.

**Estimated effort:** 2a = 1 day. 2b = half day. Both together ≈ 1.5 days.

---

### 3. CI + real test target (was item #3)

**Goal:** a green badge in the README. Says "professional habits" cheaply.

**Why third:** after items 1 and 2 stabilise, lock in the surface with CI so future README changes don't ship broken code.

**Tasks:**

- Promote `BioAgeProfileTests.swift` from `#if DEBUG` harness to a real **XCTest** target. Convert the precondition-based sanity checks into `XCTAssert*` calls. Keep the four synthetic profiles (elite endurance, metabolic syndrome ±bloodwork, vegan low-exercise).
- Optionally add ~5 small unit tests around the riskiest pure functions: `evaluate()` z-score path, freshness weighting, sensitivity computation (if 2b shipped), the `MealFingerprint` decode path.
- Add `.github/workflows/ci.yml` running `xcodebuild test` on `macos-latest` with the iOS simulator. Cache derived data.
- Add the badge to the README (README work is the next-session task, but the badge URL can be prepared in this step).

**Done when:** `xcodebuild test` runs green locally, GitHub Actions runs green on push to `main`, badge is ready.

**Estimated effort:** 2–4 hours.

---

### 4. On-device LLM via Foundation Models (was item #1) — DEFERRED

**Status:** parked. Current iPhone does not support Apple Intelligence, so this can't be developed or demoed.

**When to revisit:** when a Foundation-Models-capable device is available (iPhone 15 Pro / 16 / 17 series). Until then, *do not* mention Foundation Models in the README — it would be a claim without evidence.

**Note for that future session:** the design when you pick this back up is — local Foundation Models model writes the natural-language bio-age summary ("HRV is your biggest lever this week — here's why") and optionally an offline meal-description fallback. The cloud Claude call stays for the harder image-vision task. The story becomes: *"hybrid AI — local model for cheap/private text, cloud vision model for the hard image task."*

In the meantime, item 2 (cybernetics framing) carries the technical-depth load alone. That's fine — the cybernetics angle is actually a sharper differentiator for the German engineering job market than "I used Apple's on-device LLM," which any iOS dev will soon be doing.

---

## Execution order recap

1. **Scope-closure audit** — close any loose ends, produce `docs/scope.md`. (~half day)
2. **Cybernetics framing** — HRV smoother + methodology doc update; ideally also sensitivity readout. (~1.5 days)
3. **CI + XCTest target** — real tests + GitHub Actions badge. (~half day)
4. **Foundation Models on-device LLM** — deferred until capable hardware.

After all three: README + screenshots + 30-second demo GIF/video. That work is explicitly out of scope of this plan — handle it in a follow-up session.

---

## Anti-goals (do not do)

- No backend / no cloud user accounts.
- No Apple Watch app in this original plan (later superseded by the N4x4 feature).
- No Android / multi-platform port.
- No new feature domains. The surface is already broad enough.
- No README work in this plan — it depends on items 1–3 landing first.
- No claims about Foundation Models / on-device LLM until item 4 is actually shipped.
