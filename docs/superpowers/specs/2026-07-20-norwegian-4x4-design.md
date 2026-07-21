# Norwegian 4x4 — Design Spec

Date: 2026-07-20

## 1. Goal

A new standalone tab ("N4x4", icon: `hammer.fill` — closest available SF Symbol to
a Thor's-hammer motif) implementing the Norwegian 4x4 interval protocol, with a
companion watchOS app. The core value proposition is real-time, HR-driven
coaching feedback (via haptics) that treats heart rate as a controllable
trend rather than a value to chase instantly — avoiding overshoot during the
high-intensity ramp-up.

Track tab has been removed from the app entirely as part of this change
(dead feature, unused). N4x4 takes a new top-level tab slot. It may move under
a "Cardio" submenu in the future, but ships as a main tab for now.

## 2. Protocol structure

Fixed, non-configurable in v1 (warm-up/cooldown are skippable in-session, but
duration/count/timing are not user-editable):

```
Warm-up (3 min)
→ High-intensity (4 min) → Active recovery (3 min)   [round 1]
→ High-intensity (4 min) → Active recovery (3 min)   [round 2]
→ High-intensity (4 min) → Active recovery (3 min)   [round 3]
→ High-intensity (4 min)                              [round 4]
→ Cooldown (3 min)
```

Recovery sits between high-intensity blocks only — after the 4th high block,
the protocol goes straight to cooldown (no trailing recovery block). Total
runtime = 31 minutes (3 warm-up + 4×4 high + 3×3 recovery + 3 cooldown = 1860 s).

## 3. HR target computation

- **HRmax estimate**: blend of the Tanaka formula (`208 − 0.7 × age`, using
  HealthKit date-of-birth) and the observed max HR from the last 90 days of
  vigorous-workout HR samples in HealthKit. Whichever is higher wins (a
  personal observed ceiling beats a population formula; the formula is the
  floor/fallback for users without workout history). Recomputed after every
  N4x4 session, since the session itself is likely to produce a new
  personal-best reading.
- No manual HRmax override in v1 — revisit if testing shows the automatic
  estimate is off for some users.
- **Target bands**: high-intensity phase 85–95% HRmax; active-recovery phase
  65–70% HRmax.
- **Target is a moving line, not an instant step.** At the start of each
  high-intensity block, the target ramps linearly from the user's current HR
  up to the 85–95% band over **60 seconds**, then holds flat as a band for the
  remainder of the block. Recovery blocks mirror this with their own
  ramp-down. This exists specifically to avoid commanding an unrealistic
  instant jump to target HR, which would both be physiologically impossible
  and risk mid-interval overshoot from over-correction.

## 4. Control loop / haptic logic

- HR samples are evaluated against a **10-second trailing average**, not the
  raw instantaneous sample, to reduce jitter-driven flip-flopping.
- **Dead-band**: ±8 bpm around the current target-line value. Inside the
  dead-band, no haptic fires at all.
- Outside the dead-band: fires a "go harder" haptic (below target) or "chill"
  haptic (above target). Repeat rate scales with how far outside the
  dead-band the trailing average is — approximately every 20s when just
  outside, tightening down to a 5s floor when more than 20 bpm off. The 5s
  floor exists so guidance never becomes a constant buzz.
- A separate, distinct one-shot (non-repeating) haptic fires on every phase
  transition (e.g., high-intensity → recovery).

## 5. Architecture

### 5.1 Shared engine

A platform-agnostic Swift package, `IntervalEngine`, with no UIKit/WatchKit/
HealthKit imports. Given a start timestamp, the fixed protocol config, and a
stream of HR samples, it deterministically computes: current phase, current
target-line value, dead-band state, current-phase ring progress (%), and
haptic command events (per §4). Because phase/timing is derived purely from
the shared start-timestamp, both devices' timers stay in lockstep by
construction — no state reconciliation needed for the clock itself.

This package is shared between the iOS app and a new watchOS app target.

### 5.2 Primary / mirror with automatic failover

Rather than making one device permanently authoritative, or running two fully
independent engines that could issue conflicting haptic commands:

- Whichever device starts the session becomes **primary**: it opens its own
  `HKWorkoutSession` (watchOS session API, or iOS 18's on-device workout
  session API for the no-watch/AirPods case), reads HR from whatever sensor
  is locally available to it, runs its own `IntervalEngine` instance, and
  owns haptics.
- If the other device is reachable via `WCSession`, primary streams its
  engine's live output (phase, HR, target state, ring %, haptic events) to
  it. The secondary device renders this mirrored state and does **not** run
  its own engine's haptics while mirroring — exactly one haptic authority is
  active at a time.
- The secondary device keeps a dormant local `IntervalEngine` instance primed
  with the same start-timestamp/config and its own best local HR source,
  muted while mirroring. If no tick arrives from primary for ~4–5 seconds
  (long enough to survive a normal Bluetooth hiccup, short enough to not
  leave the user without coaching for a meaningful stretch), the secondary
  auto-promotes itself to primary: unmutes its own haptics and takes over
  sensing locally. There is no auto-reclaim once promoted, to avoid
  ping-ponging primary status back and forth.

This satisfies three required operating modes without any special-casing:
- **Watch alone** (no phone / app not running there): Watch is primary from
  the first tick, fully standalone.
- **Phone alone + external HR source** (e.g. AirPods Pro 2 via iOS 18
  on-device workout session): phone is primary, fully standalone.
- **Both connected**: one is primary, the other mirrors, with seamless
  failover if the link drops mid-session.

### 5.3 Mode / source auto-detection

No manual mode picker. At session start: if the Watch app is reachable and
able to run the session, it becomes primary. Otherwise, the phone checks for
an available HR source (e.g. AirPods Pro 2). If neither a Watch nor any HR
source is available, the app falls back to a **timer-only mode** — phases and
ring/timer run normally, but no HR-based haptic guidance is given. This
fallback triggers an explicit warning pop-up at start (distinct from silent
degradation, to keep this case debuggable) so the user is never confused
about why they're not getting haptic feedback.

## 6. UI

### 6.1 Phone

- Timer in the center, circular ring around it as the progress indicator.
- Ring shows **current-phase progress only** (resets at each phase
  boundary), not overall workout progress.
- Ring color: blue during warm-up/cooldown, red during high-intensity, green
  during active recovery.
- Short text label alongside, e.g. "3/4 (high intensity)".

### 6.2 Watch

- Same ring + color scheme as phone, in a simpler/more compact layout: large
  HR number, the phase-progress ring, phase/round label, time remaining.

### 6.3 Live Activity (lock screen + Dynamic Island)

Deliberately leaner than the in-app screens:
- Current HR.
- A directional arrow (up/down) shown **only** when the user is outside the
  dead-band and needs to adjust — no arrow when in-range.
- Time remaining in the current phase.
- Same color coding as the ring (blue/red/green). No phase-name text — the
  color communicates it.

Must continue updating with the screen off (Live Activity), per the original
requirement.

## 7. Controls

- **Phone**: Skip (visible only during warm-up/cooldown), Pause/Resume, End
  Workout — always visible controls.
- **Watch**: the same full control set (Skip/Pause/Resume/End), but behind a
  swipe-left menu, matching Apple's native Workout app interaction pattern
  rather than cluttering the main watch screen.

## 8. Persistence / out of scope for v1

Explicitly deferred, noted here as open TODOs rather than silently dropped:

- **No HealthKit workout write.** The session does not get saved as a
  workout (does not contribute to Activity rings / Fitness app / Move-Exercise
  minutes) in v1.
- **No in-app post-session summary** (e.g. time-in-zone per phase, avg/peak
  HR). Session is fully ephemeral — it runs live and ends.
- **No manual HRmax override UI** — revisit based on real-world testing
  accuracy of the automatic Tanaka + observed-max blend.

SpO2 was explicitly considered and rejected as a control-loop signal: wrist
SpO2 sensing is slow (10–30s lag) and unreliable during motion, and not
designed by Apple for exercise use — HR is the right signal for real-time
guidance here.

## 9. Testing strategy

- `IntervalEngine` (ramp-line math, dead-band logic, haptic repeat-rate
  scaling, phase-transition detection) is pure Swift with no platform
  dependencies — gets full unit test coverage, no device required.
- Primary/mirror failover behavior, real sensor behavior (Watch wrist sensor
  vs. AirPods Pro 2), and actual haptic feel all require physical-device
  testing — none of this is exercisable in the simulator, since
  `HKWorkoutSession` sensors and real Taptic feedback don't simulate.
