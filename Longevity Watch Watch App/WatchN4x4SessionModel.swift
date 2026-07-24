import Foundation
import IntervalEngine
import Observation

/// Drives a Norwegian 4x4 session on the watch. The watch is the preferred
/// *primary* (wrist HR via `HKWorkoutSession`), but it can also *mirror* a phone
/// that started first, and auto-promote itself if the phone's link drops
/// (spec §5.2). The promotion *decision* lives in the tested `FailoverController`;
/// this model owns the sensing, engine, haptics and role transitions.
@Observable
@MainActor
final class WatchN4x4SessionModel {

    /// Screen state. `active` = we are primary (local engine + haptics);
    /// `mirroring` = rendering a remote primary's output with haptics muted.
    enum Stage: Equatable { case idle, active, mirroring, done }

    private(set) var stage: Stage = .idle
    private(set) var output: EngineOutput?
    private(set) var hrMax: Double?
    private(set) var latestHR: Double?

    /// Why the session fell back to timer-only — drives the reason-specific
    /// warning copy the watch surfaces (spec §5.3). "No HR source" was misleading:
    /// the wrist sensor is fine; these are the real reasons zones get disabled.
    enum TimerOnlyReason: Equatable {
        case noHRMax       // no DOB and no 90-day history → can't build target zones
        case sensorFailed  // HKWorkoutSession wouldn't open
        case noReadings    // session opened but no HR samples arrived in the grace window
    }

    private(set) var timerOnlyReason: TimerOnlyReason = .noHRMax

    /// Surfaced once when a standalone session falls back to timer-only, so the
    /// watch UI can show the reason-specific warning (spec §5.3).
    var showTimerOnlyWarning = false

    private let workout = WatchWorkoutManager()
    private let haptics = WatchHapticEngine()
    private let connectivity = WatchConnectivityManager()
    private var engine: IntervalEngine?
    private var failover: FailoverController?
    private var ticker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var graceCheck: Task<Void, Never>?
    private var receivedAnyHR = false
    private var didSetUp = false

    private var mockHR: Double = 80
    private var useMockHR = false

    // MARK: - Setup

    /// Called once when the root view appears: activate the link and listen for a
    /// phone that is already primary so we can mirror it (spec §5.2/§5.3).
    func onAppear() {
        guard !didSetUp else { return }
        didSetUp = true
        #if DEBUG
        useMockHR = MockMode.isActive
        #endif
        connectivity.onRemoteOutput = { [weak self] output in self?.handleRemoteOutput(output) }
        connectivity.onRemoteStop = { [weak self] in self?.handleRemoteStop() }
        connectivity.activate()
        if !useMockHR {
            Task { _ = await workout.requestAuthorization() }
        }
    }

    // MARK: - Primary (this watch runs the session)

    func startPrimary() async {
        guard stage == .idle || stage == .done else { return }
        failover = nil
        receivedAnyHR = false
        latestHR = nil
        showTimerOnlyWarning = false
        mockHR = 80

        if useMockHR {
            hrMax = 188
        } else {
            hrMax = await workout.estimatedHRMax()
        }

        let engine = IntervalEngine(hrMax: hrMax, startedAt: Date())
        self.engine = engine
        output = engine.tick(at: Date()).output  // prime first frame

        stage = .active
        beginSensing()
        ticker = Task { [weak self] in await self?.runLoop() }
    }

    /// Always open the wrist sensor (unless mocking) so live HR remains visible
    /// even when target zones are unavailable. Coaching resumes automatically if
    /// readings arrive later; the warning only explains the current degradation.
    private func beginSensing() {
        guard !useMockHR else { return }
        let started = workout.start { [weak self] bpm, date in self?.ingest(bpm: bpm, at: date) }
        if !started {
            timerOnlyReason = .sensorFailed
            showTimerOnlyWarning = true
        } else if hrMax == nil {
            timerOnlyReason = .noHRMax
            showTimerOnlyWarning = true
        } else {
            scheduleHRArrivalCheck()
        }
    }

    /// If no real HR sample lands within the grace window, surface the timer-only
    /// warning — distinct from silent degradation (spec §5.3). This no longer
    /// latches a mode; if HR shows up later, coaching resumes on its own.
    private func scheduleHRArrivalCheck() {
        graceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.stage == .active, !self.useMockHR else { return }
            if !self.receivedAnyHR {
                self.timerOnlyReason = .noReadings
                self.showTimerOnlyWarning = true
            }
        }
    }

    private func runLoop() async {
        guard let engine else { return }
        while !Task.isCancelled, stage == .active {
            let now = Date()
            if useMockHR, !engine.isPaused {
                let bpm = nextMockHR()
                engine.ingest(hrSample: bpm, at: now)
                latestHR = bpm
                receivedAnyHR = true
            }
            let result = engine.tick(at: now)
            output = result.output
            connectivity.send(result.output)  // let a phone mirror this primary
            // Engine self-gates coaching: goHarder/chill only fire with live HR +
            // a target, phaseTransition always. So play everything unconditionally
            // — timer-only just means no HR, hence no coaching cues this tick.
            for command in result.haptics { haptics.play(command) }
            if result.output.isFinished {
                finish()
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Mirror (a phone is primary)

    private func handleRemoteOutput(_ remote: EngineOutput) {
        switch stage {
        case .active, .done:
            return  // we own the session; no auto-yield (spec §5.2)
        case .idle:
            failover = FailoverController(role: .mirror, referenceStart: Date())
            stage = .mirroring
            startWatchdog()
            fallthrough
        case .mirroring:
            output = remote
            latestHR = remote.trailingHR
            failover?.receivedPrimaryTick(at: Date())
            if remote.isFinished { endMirror(toDone: true) }
        }
    }

    /// Local timer that promotes this mirror to primary if the primary's stream
    /// goes quiet past the watchdog window (spec §5.2). No auto-reclaim.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.stage == .mirroring else { return }
                if self.failover?.evaluate(at: Date()) == true {
                    await self.promoteToPrimary()
                    return
                }
            }
        }
    }

    /// Take over from a lost primary, seeding the local clock to the last mirrored
    /// elapsed so the timeline stays continuous, then unmute local haptics.
    private func promoteToPrimary() async {
        guard stage == .mirroring else { return }
        watchdog?.cancel(); watchdog = nil
        receivedAnyHR = false
        mockHR = latestHR ?? 80

        let elapsed = output?.elapsed ?? 0
        if useMockHR {
            hrMax = 188
        } else {
            hrMax = await workout.estimatedHRMax()
        }

        // The await yields the main actor. An explicit remote stop or finished
        // output may have ended mirroring while HealthKit was being queried.
        guard stage == .mirroring else { return }

        let engine = IntervalEngine(hrMax: hrMax, startedAt: Date().addingTimeInterval(-elapsed))
        self.engine = engine
        output = engine.tick(at: Date()).output

        stage = .active
        beginSensing()
        ticker = Task { [weak self] in await self?.runLoop() }
    }

    // MARK: - Controls (spec §7) — only meaningful while we are primary.

    func pauseResume() {
        guard stage == .active, let engine else { return }
        let now = Date()
        if engine.isPaused { engine.resume(at: now) } else { engine.pause(at: now) }
        output = engine.tick(at: now).output
    }

    @discardableResult
    func skip() -> Bool {
        guard stage == .active, let engine else { return false }
        let now = Date()
        let didSkip = engine.skip(at: now)
        if didSkip { output = engine.tick(at: now).output }
        return didSkip
    }

    var canSkip: Bool {
        stage == .active && output?.phase.isSkippable == true && !(output?.isFinished ?? false)
    }

    var canControl: Bool { stage == .active }

    func end() {
        let wasFinished = output?.isFinished ?? false
        connectivity.sendStop()  // tell a mirror this was intentional, not a dropped link
        teardown()
        stage = wasFinished ? .done : .idle
    }

    /// The remote primary explicitly ended the session: tear down and return to
    /// idle instead of treating the ensuing silence as a failover trigger.
    private func handleRemoteStop() {
        switch stage {
        case .active, .mirroring:
            teardown()
            stage = .idle
        case .idle, .done:
            break
        }
    }

    private func finish() { teardown(); stage = .done }

    private func endMirror(toDone: Bool) { teardown(); stage = toDone ? .done : .idle }

    private func teardown() {
        ticker?.cancel(); ticker = nil
        watchdog?.cancel(); watchdog = nil
        graceCheck?.cancel(); graceCheck = nil
        workout.stop()
        engine = nil
        failover = nil
    }

    // MARK: - Input

    private func ingest(bpm: Double, at date: Date) {
        guard stage == .active, let engine else { return }
        receivedAnyHR = true
        latestHR = bpm
        engine.ingest(hrSample: bpm, at: date)
    }

    private func nextMockHR() -> Double {
        let desired: Double
        if let target = output?.target {
            desired = (target.lowerBound + target.upperBound) / 2
        } else {
            desired = (hrMax ?? 190) * 0.55
        }
        mockHR += (desired - mockHR) * 0.22 + Double.random(in: -2...2)
        return mockHR
    }
}
