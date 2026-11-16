# Longevity Compass

An iPhone and Apple Watch app that estimates how old your physiology looks compared with your
actual age. It combines 24 signals from HealthKit, bloodwork and logged behaviour into a transparent
10-factor model, and adds camera-based nutrition logging and a guided Norwegian 4×4 interval workout.

[![CI](https://github.com/fabian-kir/Longevity-Compass/actions/workflows/ci.yml/badge.svg)](https://github.com/fabian-kir/Longevity-Compass/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-iOS%2026%20%7C%20watchOS%2026-blue)
![Swift](https://img.shields.io/badge/Swift-SwiftUI%20%2B%20SwiftData-orange)

> Longevity Compass is a personal project. It is not a medical device and gives no medical advice.
> The biological-age figure is a proxy built from wearable and lab values, not a diagnosis.

## What it does

- **Biological-age estimate.** One number, the difference in years between estimated and
  chronological age, with a per-factor breakdown and the single change that would move it most.
- **Focus tab.** The most useful thing to do today, with the reasoning behind it.
- **Nutrition.** Take a photo or scan a barcode to log a meal.
- **Bloodwork.** Enter lab panels by hand (ApoB, HbA1c, hs-CRP and others) with reference ranges.
- **Training.** A strength log, and a guided Norwegian 4×4 session that runs on iPhone and Apple
  Watch with heart-rate targets, haptics and a Live Activity.

There is no backend and there are no accounts. Health data stays on the device. The one exception
is meal photos, which are sent to a vision model through OpenRouter when you use photo logging.

## The biological-age engine

`BiologicalAgeEngine` fuses noisy, irregularly sampled sensor data into one estimate under explicit
assumptions. Nothing is learned or fitted: every year the engine adds or subtracts comes from one
reading times one weight, and the result can be reproduced by hand with a calculator. The full
derivation is in [docs/biological-age-methodology.md](docs/biological-age-methodology.md).

**Additive model.** The 24 signals are grouped into 10 factors. Each factor is a mean of signed
"years impact" terms, weighted by freshness and data quality, and clamped at a per-factor cap so
that no single noisy sensor can dominate.

```
biologicalAge   = max(0, chronologicalAge + Σ clamp(weightedMean_factor, ±yearsCap_factor))

rawYearsImpact  = −zScore × yearsPerSD        (z-scored against age and sex norms)
effectiveWeight = freshnessWeight × qualityWeight
```

**Smoothing for irregular samples.** Heart-rate variability from HealthKit is noisy from night to
night and arrives at uneven intervals. Instead of a fixed-step exponential average, the engine uses
a continuous-time exponential smoother with a 7-day half-life that weights each sample by its
actual time gap, `e^(−Δt/τ)`, before z-scoring.
([methodology §5](docs/biological-age-methodology.md))

**Sensitivity readout.** The map from signal to result is piecewise linear, so the app can show a
local slope such as "10 % better HRV → −0.4 years". It is computed by finite difference and reads
zero when a factor is at its cap or suppressed.
([methodology §6](docs/biological-age-methodology.md))

**Correlated signals.** Downstream markers suppress the upstream behaviours they already capture,
so the same effect is not counted twice. Upstream drivers and the top lever are still shown in the
interface without changing the number.

## Nutrition pipeline

- **Barcode:** detected on the device with `Vision`, then looked up in OpenFoodFacts.
- **Photo:** a vision model (Claude Sonnet 4.6 through OpenRouter by default) returns a category
  fingerprint: plate fractions, plant ingredients, macros per 100 g and a typical serving size.
  The model is never asked for absolute grams, which it cannot estimate reliably from a photo.
- **Offline:** captures wait in a queue backed by `NWPathMonitor` and upload when the connection
  returns.

The API key is stored in the Keychain. The cost of each call is tracked and shown in Settings.

## Norwegian 4×4

A 31-minute protocol: warm-up, four high-intensity rounds, three active recoveries and a cooldown.

- Target heart-rate bands derived from maximum heart rate, with coaching and distinct haptic cues.
- One device owns the session and the other mirrors it. If the owner disappears, the mirror takes over.
- When heart-rate readings are missing, the session degrades to a timer with a clear warning and
  recovers when readings return.
- Completed sessions are written to Apple Health.

The timing and state logic lives in the local `IntervalEngine` package, separate from any UI.

## Architecture

| Path | Content |
|---|---|
| `Longevity Compass/Views/` | SwiftUI screens, one folder per tab, plus shared components |
| `Longevity Compass/Models/` | SwiftData models and value types |
| `Longevity Compass/Services/` | Engines and integrations: HealthKit, OpenRouter, OpenFoodFacts, Keychain |
| `Longevity Compass/Config/` | Thresholds and norms |
| `Packages/IntervalEngine/` | Interval state and timing, and the visuals shared by phone and watch |
| `Longevity Watch Watch App/` | Apple Watch companion |
| `N4x4 Live Activity/` | Live Activity for a running session |

| Engine | Responsibility |
|---|---|
| `BiologicalAgeEngine` | 24 signals → 10 factors → difference in years |
| `PriorityEngine` | Ranks 12 health domains by impact, friction, status and trend |
| `IntervalEngine` | Deterministic 4×4 timeline, target bands, coaching and failover |
| `NotificationManager` | Reminders driven by status, respecting quiet hours |

Persistence uses SwiftData with lightweight migration. Export is JSON.

Frameworks: SwiftUI, SwiftData, HealthKit, WatchConnectivity, ActivityKit, CoreHaptics, Vision, Network.

## Tests

- The app's XCTest target checks the engine against four synthetic profiles (elite endurance,
  metabolic syndrome with and without bloodwork, and a vegan low-exercise case) and asserts that
  each lands in its expected range. It also covers nutrition logic, barcode stabilisation and the
  workout recorder.
- The `IntervalEngine` package has tests for the timeline, targets, control, failover and the
  message format between phone and watch.
- GitHub Actions runs both suites on every push and pull request to `main`.

## Build and run

```bash
git clone https://github.com/fabian-kir/Longevity-Compass.git
cd Longevity-Compass
open "Longevity Compass.xcodeproj"
```

Requires Xcode with the iOS 26 and watchOS 26 SDKs.

| Scheme | Use |
|---|---|
| `Longevity Compass` | The app and its tests |
| `Longevity Compass (Mock)` | The app with synthetic data, for the simulator |
| `Longevity Watch Watch App` | The watch companion |

Health data comes from HealthKit. Photo logging needs an OpenRouter API key, entered in Settings.

## Scope

The feature list and what is deliberately left out are in [docs/scope.md](docs/scope.md).

---

Built by Fabian Kirschenmann.
