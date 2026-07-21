# Norwegian 4x4 — Implementation Notes

Companion to `2026-07-20-norwegian-4x4-design.md`. Records what shipped in this
pass, decisions made against the spec, and the remaining pieces that require
Xcode-GUI target creation (which cannot be done safely by hand-editing the
`project.pbxproj`).

## What shipped (built + verified)

### `Packages/IntervalEngine` — platform-agnostic core (spec §5.1)

Pure Swift package, no UIKit/WatchKit/HealthKit. Deterministic: all time is
injected via `at:` parameters, so it is fully unit-testable on the host and
keeps mirrored devices in lockstep by construction.

- `Protocol.swift` — `PhaseKind`, `Phase`, `ProtocolConfig.norwegian4x4`, ring
  colors, labels, skippability, target fractions.
- `IntervalEngine.swift` — trailing-average HR, ramp-line target band,
  dead-band state, guidance haptic cadence, phase-transition haptic, pause/
  resume/skip clock.
- `HRMaxEstimator.swift` — Tanaka + observed-max blend (spec §3).
- `FailoverController.swift` — primary/mirror promotion timer (spec §5.2),
  wired into the watch session model's mirror watchdog.
- **46 unit tests, all passing** (`swift test`): timeline, target line,
  guidance/dead-band, HRmax, failover, controls, and an `EngineOutput` Codable
  round-trip (the payload streamed primary→mirror).

The local package is wired into the app via a `XCLocalSwiftPackageReference` in
`project.pbxproj`; the app target links the `IntervalEngine` product.

### iOS "N4x4" tab (spec §6.1, §7)

- New top-level tab, icon `hammer.fill`, tint cyan (`AppTab.n4x4`).
- `Views/N4x4/RingView.swift` — current-phase progress ring, color-coded.
- `Views/N4x4/N4x4View.swift` — idle/start, live session (ring + center timer +
  phase label + HR + guidance cue + total-remaining), completion. Controls:
  Skip (only when warm-up/cooldown), Pause/Resume, End. Timer-only warning alert.
- `Views/N4x4/N4x4SessionModel.swift` — `@Observable @MainActor` controller
  driving the engine at 1 Hz, HRmax bridge, HR ingest, timer-only fallback with
  the explicit start-time warning (spec §5.3). Plays both spec §5.2 roles:
  standalone **primary** (opens its own iOS `HKWorkoutSession`) and **mirror**
  of a Watch primary with a promoting failover watchdog. Mock HR synthesis under
  `-mockData` so the flow is demoable without hardware.
- `Views/N4x4/PhoneWorkoutManager.swift` — the phone's standalone HR source
  (spec §5.2/§5.3): an iOS `HKWorkoutSession` + `HKLiveWorkoutBuilder` reading
  beat-to-beat HR from a locally paired sensor (AirPods Pro 2 / Bluetooth strap)
  when no Watch is primary. Live samples pushed to the session model.
- `Views/N4x4/N4x4HapticEngine.swift` — maps engine `HapticCommand`s to
  CoreHaptics patterns, with `UIFeedbackGenerator` fallback.
- `Services/HealthKitManager.swift` — added `.heartRate` read auth,
  `observedMaxHeartRate(days:)`, and shares `HKObjectType.workoutType()` so the
  phone can open its own `HKWorkoutSession` (the AirPods/Bluetooth path above).

Verified in the iOS Simulator (mock scheme): idle screen and a live
high-intensity session render correctly (red ring, phase progress, timer, HR,
"Go harder" cue, Skip correctly hidden). Real HR / haptics / sensor behavior
need a physical device (spec §9).

### watchOS app target (spec §5.1, §6.2)

Target `Longevity Watch Watch App`, embedded in and auto-installed by the iOS
app; the local `IntervalEngine` package is linked into it (wired via
`project.pbxproj`).

- `RingView.swift` — watch copy of the phase-progress ring + `RingColor →
  SwiftUI.Color` mapping.
- `ContentView.swift` — compact layout: HR-centered ring, phase/round label,
  time remaining, out-of-range cue arrow; swipe-left page carries Skip/Pause/
  End (spec §7); idle + completion screens; timer-only warning alert.
- `WatchN4x4SessionModel.swift` — `@Observable @MainActor` orchestrator with an
  `idle / active / mirroring / done` state machine. Runs the engine at 1 Hz when
  primary; renders a remote primary's ticks (haptics muted) when mirroring.
- `WatchWorkoutManager.swift` — `HKWorkoutSession` + `HKLiveWorkoutBuilder` for
  real wrist HR (the watch is the preferred primary, spec §5.2); HRmax from
  HealthKit DOB + observed 90-day max via the shared `HRMaxEstimator`.
- `WatchHapticEngine.swift` — maps engine `HapticCommand`s to
  `WKInterfaceDevice` haptics.
- `MockMode.swift` — `-mockData` gate; synthesizes HR so the whole flow is
  demoable in the watch Simulator (sensors don't simulate, spec §9).

Verified: the watch target compiles for both a watchOS Simulator and the
embedded generic-iOS-Simulator build, and the idle screen renders on an
Apple Watch Series 11 (46 mm) sim. Real HR, haptics, and the live session with
on-device sensors need a physical watch (spec §9).

### WCSession primary/mirror link (spec §5.2)

- `Longevity Watch Watch App/WatchConnectivityManager.swift` and
  `Longevity Compass/Views/N4x4/N4x4ConnectivityManager.swift` — thin transport;
  each `EngineOutput` tick crosses as JSON (`sendMessageData`). `EngineOutput`
  and every nested type are now `Codable` (round-trip covered by a unit test).
- The watch runs the full loop: streams its output while primary, renders a
  remote primary while mirroring, and drives promotion through the existing
  `FailoverController` (`receivedPrimaryTick(at:)` per inbound tick,
  `evaluate(at:)` on a 1 Hz watchdog). No auto-reclaim, no auto-yield.
- The phone runs the same full loop: streams its output while primary
  (`connectivity.send(_:)` each tick), renders a watch primary while mirroring
  (`onRemoteOutput` → `handleRemoteOutput`, haptics muted), and promotes itself
  through its own `FailoverController` watchdog if the watch's stream goes quiet
  — seeding the local engine to the mirrored elapsed so the timeline stays
  continuous. No auto-reclaim, no auto-yield, matching the watch.

Cross-device failover is only observable on real paired hardware (spec §9); the
per-device state machine and the promotion decision are unit-/Simulator-tested.

## Decisions & deviations

- **Total runtime is 31 min.** The block structure in spec §2
  (3 + 4×(4+3) − 3 trailing + 3 = 1860 s) sums to exactly 31 minutes;
  confirmed with the author. `ProtocolConfig` and `TimelineTests` assert 1860 s,
  and the spec prose was corrected to match.
- **iOS live HR = on-device `HKWorkoutSession`, not an anchored query.**
  `HKWorkoutSession` + `HKLiveWorkoutBuilder` are available on iOS 17+ (deploy
  target 26.4), so the phone opens its own workout session and streams
  beat-to-beat HR from a locally paired sensor (AirPods Pro 2 / Bluetooth strap)
  — the "phone alone + external HR source" mode (spec §5.2/§5.3). This replaced
  an earlier anchored-query sketch, which lagged several seconds and couldn't
  serve real-time coaching. (The unused `startHeartRateStream` anchored helpers
  remain in `HealthKitManager` but are no longer on the N4x4 path.)
- **`EngineOutput` is the wire contract.** It plus every nested type
  (`PhaseKind` with associated values, `RingColor`, `DeadBandState`,
  `AdjustmentHint`, `HapticCommand`, the `ClosedRange<Double>` target) is
  `Codable`, so the same struct that drives the UI is streamed verbatim
  primary→mirror — no parallel DTO to drift.
- **Grace-check tasks are now tracked.** Both session models store the
  timer-only grace-check `Task` and cancel it in teardown (previously fire-and-
  forget, safe only via a state guard).

## On-device setup still required (Xcode Signing & Capabilities)

The apps build and run in the Simulator today. For real HR on physical
hardware, enable in Xcode (entitlements aren't safe to hand-edit):

- **Watch target:** HealthKit capability + **Background Modes ▸ Workout
  processing** (keeps the wrist `HKWorkoutSession` alive with the screen off).
- **Phone target:** HealthKit is already enabled; add **Background Modes ▸
  Workout processing** so the phone's own `HKWorkoutSession` (AirPods/Bluetooth
  HR path) keeps streaming with the screen off. This is the same toggle as on
  the watch, just on the `Longevity Compass` iOS target.

## Deferred — requires a new Xcode target (GUI only)

### Live Activity / Widget extension (spec §6.3)

Not addable by hand-editing `project.pbxproj` without risking corruption
(`objectVersion 77`, synchronized file groups) — add in Xcode. The `Codable`
`EngineOutput` is ready to drive the `ContentState`.

1. File ▸ New ▸ Target ▸ **Widget Extension**, "Include Live Activity".
2. Define `ActivityAttributes` whose `ContentState` carries the lean payload:
   current HR, `AdjustmentHint` (arrow only when out of range), phase time
   remaining, `RingColor`. No phase-name text — color communicates phase.
3. Start the activity when a session begins; update it each engine tick from
   `EngineOutput`. Add `NSSupportsLiveActivities = YES` to the app `Info.plist`.

### Follow-ups (code, no new target)

- Out of scope for v1 (spec §8): no HealthKit workout write, no post-session
  summary, no manual HRmax override.
