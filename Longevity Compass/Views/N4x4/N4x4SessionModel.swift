import Foundation
import IntervalEngine
import Observation

/// Drives a live Norwegian 4x4 session on the phone: owns the deterministic
/// `IntervalEngine`, a heart-rate source, and the haptic engine, and ticks once
/// per second to publish an `EngineOutput` for the UI to render.
///
/// Plays both spec §5.2 roles. As **primary** (phone-alone) it opens its own
/// iOS `HKWorkoutSession` via `PhoneWorkoutManager` to read HR from a local
/// sensor (AirPods Pro 2 / Bluetooth strap) and owns haptics. As **mirror** it
/// renders a Watch primary's streamed `EngineOutput` with haptics muted, and if
/// that stream goes quiet past the `FailoverController` watchdog it promotes
/// itself — seeding a local engine to the mirrored elapsed time and taking over
/// sensing. No auto-reclaim, no auto-yield.
@Observable
@MainActor
final class N4x4SessionModel {

    private(set) var output: EngineOutput?
    private(set) var isRunning = false
    /// True while rendering a remote Watch primary (haptics muted). Distinct from
    /// `isRunning`, which means this device owns the engine + haptics.
    private(set) var isMirroring = false
    private(set) var hrMax: Double?
    private(set) var latestHR: Double?

    /// Set true once when the session starts without an HR source, so the UI can
    /// surface the explicit timer-only warning (spec §5.3). The View clears it.
    var showTimerOnlyWarning = false

    private var healthKit: HealthKitManager?
    private var dateOfBirth: Date?
    private let workout = PhoneWorkoutManager()
    private let haptics = N4x4HapticEngine()
    private let connectivity = N4x4ConnectivityManager()
    private var engine: IntervalEngine?
    private var failover: FailoverController?
    private var ticker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var graceCheck: Task<Void, Never>?
    private var connectivityActivated = false
    private var receivedAnyHR = false

    // Mock HR synthesis (Simulator / -mockData): a first-order lag toward the
    // current target midpoint, so the demo exercises ramps, dead-band and haptics.
    private var mockHR: Double = 80
    private var useMockHR = false

    // MARK: - Lifecycle

    /// Called when the N4x4 screen appears. Activates the link and starts
    /// listening for a Watch that is already primary, so the phone can mirror it
    /// (and later promote itself) even before the user taps Start (spec §5.2).
    func onAppear(healthKit: HealthKitManager, dateOfBirth: Date?) {
        self.healthKit = healthKit
        self.dateOfBirth = dateOfBirth
        #if DEBUG
        useMockHR = MockMode.isActive
        #endif
        connectivity.onRemoteOutput = { [weak self] remote in self?.handleRemoteOutput(remote) }
        connectivity.onRemoteStop = { [weak self] in self?.handleRemoteStop() }
        activateConnectivityIfNeeded()
    }

    private func activateConnectivityIfNeeded() {
        guard !connectivityActivated else { return }
        connectivityActivated = true
        connectivity.activate()
    }

    func start(healthKit: HealthKitManager, dateOfBirth: Date?) async {
        guard !isRunning, !isMirroring else { return }
        self.healthKit = healthKit
        self.dateOfBirth = dateOfBirth

        let observedMax = try? await healthKit.observedMaxHeartRate(days: 90)
        // The await above yields the main actor: a Watch mirror or a watchdog
        // promotion may have taken over the session meanwhile. Bail rather than
        // spawn a second engine + ticker on top of it (which would double-tick
        // output and the connectivity stream).
        guard !isRunning, !isMirroring else { return }
        hrMax = HRMaxEstimator.estimate(dateOfBirth: dateOfBirth, observedMaxLast90d: observedMax)

        let engine = IntervalEngine(hrMax: hrMax, startedAt: Date())
        self.engine = engine
        receivedAnyHR = false
        latestHR = nil
        showTimerOnlyWarning = false
        mockHR = 80
        // Prime the first frame so a restart never flashes the prior session's
        // finished output before the tick loop produces its first snapshot.
        output = engine.tick(at: Date()).output

        beginSensing()

        haptics.prepare()
        activateConnectivityIfNeeded()  // phone is primary here → stream ticks to a watch mirror (spec §5.2)
        isRunning = true
        ticker = Task { [weak self] in await self?.runLoop() }
    }

    /// Start HR sensing for a primary session. Always opens the local workout
    /// session (AirPods / Bluetooth sensor) unless mocking, so live HR shows even
    /// without zones. Timer-only is now a transient, derived state — coaching
    /// resumes automatically once HR arrives (the engine self-gates its coaching
    /// haptics on live HR + a target); we only surface a warning here.
    private func beginSensing() {
        guard !useMockHR else { return }
        let started = workout.start { [weak self] bpm, date in self?.ingest(bpm: bpm, at: date) }
        if !started || hrMax == nil {
            showTimerOnlyWarning = true
        } else {
            scheduleHRArrivalCheck()
        }
    }

    /// If no real HR sample has landed within the grace window, surface the
    /// timer-only warning — distinct from silent degradation (spec §5.3). This no
    /// longer latches a mode; coaching resumes on its own if HR shows up later.
    private func scheduleHRArrivalCheck() {
        graceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.isRunning, !self.useMockHR else { return }
            if !self.receivedAnyHR {
                self.showTimerOnlyWarning = true
            }
        }
    }

    func end() {
        connectivity.sendStop()  // tell a mirror this was intentional, not a dropped link
        stopLocally()
    }

    /// The remote primary explicitly ended the session: tear down without
    /// re-broadcasting, instead of treating the silence as a failover trigger.
    private func handleRemoteStop() {
        guard isRunning || isMirroring else { return }
        stopLocally()
    }

    private func stopLocally() {
        isRunning = false
        isMirroring = false
        ticker?.cancel(); ticker = nil
        watchdog?.cancel(); watchdog = nil
        graceCheck?.cancel(); graceCheck = nil
        workout.stop()
        haptics.stop()
        engine = nil
        failover = nil
    }

    // MARK: - Mirror (a Watch is primary) — spec §5.2

    /// Fold in a tick from a remote primary. Ignored while we own the session
    /// (no auto-yield); otherwise render it and feed the failover watchdog.
    private func handleRemoteOutput(_ remote: EngineOutput) {
        guard !isRunning else { return }  // we're primary → no auto-yield
        if !isMirroring {
            failover = FailoverController(role: .mirror, referenceStart: Date())
            isMirroring = true
            startWatchdog()
        }
        output = remote
        latestHR = remote.trailingHR
        failover?.receivedPrimaryTick(at: Date())
        if remote.isFinished { endMirror() }
    }

    /// Local timer that promotes this mirror to primary if the primary's stream
    /// goes quiet past the watchdog window (spec §5.2). No auto-reclaim.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isMirroring else { return }
                if self.failover?.evaluate(at: Date()) == true {
                    await self.promoteToPrimary()
                    return
                }
            }
        }
    }

    /// Take over from a lost Watch primary, seeding the local clock to the last
    /// mirrored elapsed so the timeline stays continuous, then start local
    /// sensing + haptics.
    private func promoteToPrimary() async {
        guard isMirroring else { return }
        watchdog?.cancel(); watchdog = nil
        let elapsed = output?.elapsed ?? 0
        receivedAnyHR = false
        mockHR = latestHR ?? 80

        let observedMax: Double?
        if let healthKit {
            observedMax = try? await healthKit.observedMaxHeartRate(days: 90)
        } else {
            observedMax = nil
        }
        // The await above yields; if the remote primary's finished tick landed
        // during it, `endMirror()` already cleared mirroring — don't promote a
        // session the primary just ended.
        guard isMirroring else { return }
        hrMax = HRMaxEstimator.estimate(dateOfBirth: dateOfBirth, observedMaxLast90d: observedMax)

        let engine = IntervalEngine(hrMax: hrMax, startedAt: Date().addingTimeInterval(-elapsed))
        self.engine = engine
        output = engine.tick(at: Date()).output

        beginSensing()

        haptics.prepare()
        isMirroring = false
        isRunning = true
        ticker = Task { [weak self] in await self?.runLoop() }
    }

    /// The remote primary finished: stop mirroring and let the finished frame
    /// drive the completion screen.
    private func endMirror() {
        watchdog?.cancel(); watchdog = nil
        failover = nil
        isMirroring = false
    }

    // MARK: - Controls (spec §7)

    func pauseResume() {
        guard let engine else { return }
        let now = Date()
        if engine.isPaused { engine.resume(at: now) } else { engine.pause(at: now) }
        output = engine.tick(at: now).output
    }

    /// Skip is only meaningful for warm-up/cooldown; the engine enforces that.
    @discardableResult
    func skip() -> Bool {
        guard let engine else { return false }
        let now = Date()
        let didSkip = engine.skip(at: now)
        if didSkip { output = engine.tick(at: now).output }
        return didSkip
    }

    var canSkip: Bool {
        output?.phase.isSkippable == true && !(output?.isFinished ?? false)
    }

    // MARK: - Input

    private func ingest(bpm: Double, at date: Date) {
        guard let engine, isRunning else { return }
        receivedAnyHR = true
        latestHR = bpm
        engine.ingest(hrSample: bpm, at: date)
    }

    // MARK: - Loop

    private func runLoop() async {
        guard let engine else { return }
        while !Task.isCancelled, isRunning {
            let now = Date()
            if useMockHR, !engine.isPaused {
                let bpm = nextMockHR()
                engine.ingest(hrSample: bpm, at: now)
                latestHR = bpm
                receivedAnyHR = true
            }
            let result = engine.tick(at: now)
            output = result.output
            connectivity.send(result.output)
            // Engine self-gates coaching: goHarder/chill only fire with live HR +
            // a target, phaseTransition always. Play everything unconditionally —
            // timer-only just means no HR, hence no coaching cues this tick.
            for command in result.haptics { haptics.play(command) }
            if result.output.isFinished {
                end()
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func nextMockHR() -> Double {
        let desired: Double
        if let target = output?.target {
            desired = (target.lowerBound + target.upperBound) / 2
        } else {
            desired = (hrMax ?? 190) * 0.55  // warm-up / cooldown drift
        }
        // First-order lag toward the target so the sim ramps rather than jumps,
        // plus light noise; the lag naturally produces "below" on rising ramps
        // and "above" on the recovery ramp-down, exercising both haptics.
        mockHR += (desired - mockHR) * 0.22 + Double.random(in: -2...2)
        return mockHR
    }
}
