import Foundation
import IntervalEngine
import Observation

/// App-lifetime Watch coordinator. Whenever a Watch is present it owns the
/// protocol engine and wrist heart-rate stream, regardless of which device the
/// user used to start the session. A phone checkpoint is adopted without
/// resetting elapsed time; connection loss never stops the local workout.
@Observable
@MainActor
final class WatchN4x4SessionModel {
    static let shared = WatchN4x4SessionModel()

    enum Stage: Equatable { case idle, active, mirroring, done }

    enum TimerOnlyReason: Equatable {
        case noHRMax
        case sensorFailed
        case noReadings
    }

    private(set) var stage: Stage = .idle
    private(set) var output: EngineOutput?
    private(set) var hrMax: Double?
    private(set) var heartRateSource: HeartRateSource = .none
    private(set) var latestHR: Double?
    private(set) var timerOnlyReason: TimerOnlyReason = .noHRMax
    var showTimerOnlyWarning = false

    private let workout = WatchWorkoutManager()
    private let haptics = WatchHapticEngine()
    private let connectivity = WatchConnectivityManager()

    private var engine: IntervalEngine?
    private var currentSnapshot: SessionSnapshot?
    private var sessionID: UUID?
    private var sessionCreatedAt: Date?
    private var sequence: UInt64 = 0
    private var ticker: Task<Void, Never>?
    private var graceCheck: Task<Void, Never>?
    private var sensorRetryTask: Task<Void, Never>?
    private var systemStartTask: Task<Void, Never>?
    private var pendingStartID: UUID?
    private var receivedAnyHR = false
    private var heartRateSessionActive = false
    private var authorizationTask: Task<Bool, Never>?
    private var processedCommandIDs: Set<UUID> = []
    private var acknowledgedCommandIDs: [UUID] = []
    private var stoppedSessionIDs: Set<UUID> = []

    private var mockHR: Double = 80
    private var useMockHR = false

    init() {
        #if DEBUG
        useMockHR = MockMode.isActive
        #endif

        connectivity.onRemoteMessage = { [weak self] message in
            self?.handleRemoteMessage(message)
        }
        connectivity.onReachabilityChanged = { [weak self] reachable in
            self?.handleReachabilityChange(reachable)
        }
        connectivity.activate()

        workout.onRemoteMessage = { [weak self] message in
            self?.handleRemoteMessage(message)
        }
        workout.onRemoteDisconnect = { _ in
            // Transport loss is deliberately not a workout/session event. The
            // wrist engine, sensor, timer, haptics, and status icon keep running.
        }
        workout.onSessionFailure = { [weak self] _ in
            self?.handleSensorSessionFailure()
        }
        workout.onSessionEnded = { [weak self] in
            // HealthKit's ended state does not identify *why* it ended. Preserve
            // the protocol unless the separately authenticated session command
            // says stop; meanwhile retry wrist sensing like any other failure.
            self?.handleSensorSessionFailure()
        }
    }

    func onAppear() {
        Task { _ = await ensureAuthorization() }
    }

    private func ensureAuthorization() async -> Bool {
        if useMockHR { return true }
        if let authorizationTask { return await authorizationTask.value }

        let task = Task { [workout] in
            await workout.requestAuthorization()
        }
        authorizationTask = task
        return await task.value
    }

    /// Called by `WKApplicationDelegate` after iPhone uses HealthKit's
    /// `startWatchApp`. Give the pending WCSession checkpoint a short chance to
    /// arrive; if it does not, begin locally and reconcile when it does.
    func handleSystemWorkoutStart() async {
        _ = await ensureAuthorization()
        if stage == .active {
            publishCurrentFrame()
            _ = await workout.startMirroring()
            return
        }

        systemStartTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled,
                  self.stage == .idle || self.stage == .done else { return }
            await self.startPrimary()
        }
        systemStartTask = task
        await task.value
    }

    // MARK: - Watch authority

    func startPrimary() async {
        guard stage == .idle || stage == .done else { return }
        _ = await ensureAuthorization()
        guard stage == .idle || stage == .done else { return }

        let startID = UUID()
        pendingStartID = startID
        let maxHR: Double?
        if useMockHR {
            maxHR = 188
        } else {
            maxHR = await workout.estimatedHRMax()
        }

        // A phone checkpoint or stop may have arrived while HealthKit queried.
        guard pendingStartID == startID,
              stage == .idle || stage == .done else { return }
        pendingStartID = nil

        let now = Date()
        beginWatchAuthority(
            engine: IntervalEngine(hrMax: maxHR, startedAt: now),
            sessionID: UUID(),
            createdAt: now,
            startingSequence: 0
        )
    }

    private func beginWatchAuthority(
        engine: IntervalEngine,
        sessionID: UUID,
        createdAt: Date,
        startingSequence: UInt64,
        initialAcknowledgedCommandIDs: [UUID] = []
    ) {
        let continuesExistingSession = self.sessionID == sessionID
        cancelRuntimeTasks()

        // Swapping protocol checkpoints must not restart a healthy optical
        // workout. `start` reuses the existing session and only updates its HR
        // callback, avoiding a sensor/indicator gap during phone handoff.
        if !continuesExistingSession {
            acknowledgedCommandIDs = initialAcknowledgedCommandIDs
        } else {
            for commandID in initialAcknowledgedCommandIDs { acknowledge(commandID) }
        }
        processedCommandIDs.formUnion(initialAcknowledgedCommandIDs)

        self.engine = engine
        self.sessionID = sessionID
        sessionCreatedAt = createdAt
        sequence = startingSequence
        hrMax = engine.hrMax
        receivedAnyHR = false
        latestHR = nil
        heartRateSource = .none
        heartRateSessionActive = false
        showTimerOnlyWarning = false
        mockHR = 80
        stage = .active

        let result = engine.tick(at: Date())
        output = result.output
        _ = beginSensing()
        publish(result.output)
        ticker = Task { [weak self, weak engine] in
            guard let engine else { return }
            await self?.runLoop(engine: engine, sessionID: sessionID)
        }
    }

    @discardableResult
    private func beginSensing() -> Bool {
        guard stage == .active else { return false }
        if useMockHR {
            heartRateSessionActive = true
            return true
        }
        let opened = workout.start { [weak self] bpm, date in
            self?.ingest(bpm: bpm, at: date)
        }
        heartRateSessionActive = opened
        if !opened {
            timerOnlyReason = .sensorFailed
            showTimerOnlyWarning = true
            scheduleSensorRetry()
        } else if hrMax == nil {
            timerOnlyReason = .noHRMax
            showTimerOnlyWarning = true
            scheduleHRArrivalCheck()
        } else {
            scheduleHRArrivalCheck()
        }
        if opened {
            if engine?.isPaused == true { workout.pause() } else { workout.resume() }
        }
        return opened
    }

    private func scheduleSensorRetry() {
        guard sensorRetryTask == nil else { return }
        sensorRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.stage == .active else { return }
                if self.beginSensing() {
                    self.sensorRetryTask = nil
                    self.showTimerOnlyWarning = self.hrMax == nil
                    self.publishCurrentFrame()
                    return
                }
            }
        }
    }

    private func handleSensorSessionFailure() {
        guard stage == .active else { return }
        heartRateSessionActive = false
        receivedAnyHR = false
        heartRateSource = .none
        timerOnlyReason = .sensorFailed
        showTimerOnlyWarning = true
        publishCurrentFrame()
        scheduleSensorRetry()
    }

    private func scheduleHRArrivalCheck() {
        graceCheck?.cancel()
        graceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.stage == .active, !self.useMockHR else { return }
            if !self.receivedAnyHR {
                self.timerOnlyReason = .noReadings
                self.showTimerOnlyWarning = true
            }
        }
    }

    // MARK: - Reconciliation

    private func handleRemoteMessage(_ message: SessionMessage) {
        switch message {
        case .snapshot(let snapshot):
            handleRemoteSnapshot(snapshot)
        case .command(let command):
            handleRemoteCommand(command)
        }
    }

    private func handleRemoteSnapshot(_ remote: SessionSnapshot) {
        guard !stoppedSessionIDs.contains(remote.sessionID) else { return }

        let localForConflict = stage == .active ? currentSnapshot : nil
        guard SessionReconciliation.shouldAdopt(
            remote: remote,
            over: localForConflict,
            localDevice: .watch
        ) else {
            if stage == .active { publishCurrentFrame() }
            return
        }

        guard remote.authority == .phone else { return }
        if remote.output.isFinished {
            stoppedSessionIDs.insert(remote.sessionID)
            trimTerminalHistory()
            stopRuntime(clearOutput: false, finalStage: .done)
            output = remote.output
            currentSnapshot = remote
            return
        }

        // Preserve all clock/pause/skip/ramp state, but start a clean HR buffer:
        // from this moment the Watch optical sensor is the sole HR authority.
        let restored = IntervalEngine(
            checkpoint: remote.checkpoint,
            includeHeartRateHistory: false
        )
        beginWatchAuthority(
            engine: restored,
            sessionID: remote.sessionID,
            createdAt: remote.createdAt,
            startingSequence: remote.sequence,
            initialAcknowledgedCommandIDs: remote.acknowledgedCommandIDs
        )
    }

    private func handleReachabilityChange(_ reachable: Bool) {
        guard stage == .active else { return }
        if reachable {
            publishCurrentFrame()
            Task { _ = await workout.startMirroring() }
        }
        // On loss there is intentionally nothing to do: Watch is already the
        // local authority and its HKWorkoutSession keeps it alive in background.
    }

    // MARK: - Controls

    func pauseResume() {
        guard let output else { return }
        performLocalAction(.setPaused(!output.isPaused), broadcastCommand: true)
    }

    @discardableResult
    func skip() -> Bool {
        guard canSkip else { return false }
        performLocalAction(.skip, broadcastCommand: true)
        return true
    }

    var canSkip: Bool {
        stage == .active
            && output?.phase.isSkippable == true
            && !(output?.isFinished ?? false)
    }

    var canControl: Bool { stage == .active }

    func end() {
        guard let sessionID else { return }
        let command = SessionCommand(sessionID: sessionID, action: .stop)
        stoppedSessionIDs.insert(sessionID)
        trimTerminalHistory()
        broadcast(.command(command))
        stopRuntime(clearOutput: true, finalStage: .idle)
    }

    private func handleRemoteCommand(_ command: SessionCommand) {
        guard !processedCommandIDs.contains(command.id),
              !acknowledgedCommandIDs.contains(command.id) else { return }
        remember(command.id)

        if case .stop = command.action {
            stoppedSessionIDs.insert(command.sessionID)
            trimTerminalHistory()
            guard command.sessionID == sessionID else { return }
            stopRuntime(clearOutput: true, finalStage: .idle)
            return
        }

        guard command.sessionID == sessionID,
              !stoppedSessionIDs.contains(command.sessionID) else { return }
        acknowledge(command.id)

        switch command.action {
        case .setPaused, .skip:
            performLocalAction(
                command.action,
                at: command.issuedAt,
                broadcastCommand: false
            )
        case .requestSync:
            publishCurrentFrame()
        case .stop:
            break
        }
    }

    private func performLocalAction(
        _ action: SessionCommand.Action,
        at now: Date = .now,
        broadcastCommand: Bool
    ) {
        guard stage == .active, let engine else { return }
        let outgoingCommand: SessionCommand? = if broadcastCommand, let sessionID {
            SessionCommand(sessionID: sessionID, issuedAt: now, action: action)
        } else {
            nil
        }
        if let outgoingCommand {
            remember(outgoingCommand.id)
            acknowledge(outgoingCommand.id)
        }
        switch action {
        case .setPaused(let paused):
            engine.setPaused(paused, at: now)
            if paused { workout.pause() } else { workout.resume() }
        case .skip:
            _ = engine.skip(at: now)
        case .stop, .requestSync:
            return
        }

        let result = engine.tick(at: now)
        output = result.output
        if let outgoingCommand {
            broadcast(.command(outgoingCommand))
        }
        publish(result.output)
    }

    // MARK: - Engine loop / HR

    private func ingest(bpm: Double, at date: Date) {
        guard stage == .active, let engine else { return }
        receivedAnyHR = true
        latestHR = bpm
        heartRateSource = .watch
        if timerOnlyReason == .noReadings || timerOnlyReason == .sensorFailed {
            showTimerOnlyWarning = false
        }
        engine.ingest(hrSample: bpm, at: date)
    }

    private func runLoop(engine: IntervalEngine, sessionID expectedSessionID: UUID) async {
        while !Task.isCancelled,
              stage == .active,
              sessionID == expectedSessionID,
              self.engine === engine {
            let now = Date()
            if useMockHR, !engine.isPaused {
                let bpm = nextMockHR()
                engine.ingest(hrSample: bpm, at: now)
                latestHR = bpm
                receivedAnyHR = true
                heartRateSource = .watch
            }

            let result = engine.tick(at: now)
            output = result.output
            publish(result.output)
            for command in result.haptics { haptics.play(command) }

            if result.output.isFinished {
                stoppedSessionIDs.insert(expectedSessionID)
                trimTerminalHistory()
                stopRuntime(
                    clearOutput: false,
                    finalStage: .done,
                    completedSessionID: expectedSessionID
                )
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func publishCurrentFrame() {
        guard stage == .active, let engine else { return }
        let result = engine.tick(at: Date())
        output = result.output
        publish(result.output)
    }

    private func publish(_ engineOutput: EngineOutput) {
        guard let engine, let sessionID, let createdAt = sessionCreatedAt else { return }
        sequence &+= 1
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            createdAt: createdAt,
            sequence: sequence,
            authority: .watch,
            heartRateSource: receivedAnyHR ? .watch : .none,
            heartRateSessionActive: heartRateSessionActive,
            acknowledgedCommandIDs: acknowledgedCommandIDs,
            output: engineOutput,
            checkpoint: engine.checkpoint()
        )
        currentSnapshot = snapshot
        heartRateSource = snapshot.heartRateSource
        broadcast(.snapshot(snapshot))
    }

    private func broadcast(_ message: SessionMessage) {
        connectivity.send(message)
        workout.beginSendingToRemote(message)
    }

    private func stopRuntime(
        clearOutput: Bool,
        finalStage: Stage,
        completedSessionID: UUID? = nil
    ) {
        pendingStartID = nil
        cancelRuntimeTasks()
        if let completedSessionID {
            _ = workout.completeWorkout(at: .now, sessionID: completedSessionID)
        } else {
            workout.teardown()
        }
        engine = nil
        stage = finalStage
        receivedAnyHR = false
        latestHR = nil
        heartRateSource = .none
        heartRateSessionActive = false
        acknowledgedCommandIDs.removeAll(keepingCapacity: true)
        sessionID = nil
        sessionCreatedAt = nil
        if clearOutput {
            output = nil
            currentSnapshot = nil
        }
    }

    private func cancelRuntimeTasks() {
        ticker?.cancel(); ticker = nil
        graceCheck?.cancel(); graceCheck = nil
        sensorRetryTask?.cancel(); sensorRetryTask = nil
        systemStartTask?.cancel(); systemStartTask = nil
    }

    private func remember(_ commandID: UUID) {
        processedCommandIDs.insert(commandID)
        if processedCommandIDs.count > 128 {
            processedCommandIDs.removeAll(keepingCapacity: true)
            processedCommandIDs.insert(commandID)
        }
    }

    private func acknowledge(_ commandID: UUID) {
        guard !acknowledgedCommandIDs.contains(commandID) else { return }
        acknowledgedCommandIDs.append(commandID)
        if acknowledgedCommandIDs.count > 32 {
            acknowledgedCommandIDs.removeFirst(acknowledgedCommandIDs.count - 32)
        }
    }

    private func trimTerminalHistory() {
        if stoppedSessionIDs.count > 32 {
            let current = sessionID
            stoppedSessionIDs.removeAll(keepingCapacity: true)
            if let current { stoppedSessionIDs.insert(current) }
        }
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
