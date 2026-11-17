import Foundation
import IntervalEngine
import Observation

/// App-lifetime coordinator for one Norwegian 4x4 protocol.
///
/// The protocol timeline is never coupled to transport availability. The phone
/// starts a local engine immediately, asks Apple Watch to assume authority, and
/// keeps running until a Watch snapshot actually arrives. While connected, the
/// Watch snapshot (including wrist HR) is canonical. If it disappears, the
/// phone restores the exact checkpoint and continues with an external source.
@Observable
@MainActor
final class N4x4SessionModel {
    enum TimerOnlyReason: Equatable {
        case noHRMax
        case sensorFailed
        case noReadings
    }

    private(set) var output: EngineOutput?
    private(set) var isRunning = false
    private(set) var isMirroring = false
    private(set) var hrMax: Double?
    private(set) var heartRateSource: HeartRateSource = .none
    var workoutDetails = N4x4WorkoutDetails()
    var showTimerOnlyWarning = false
    private(set) var timerOnlyReason: TimerOnlyReason = .noReadings

    var timerOnlyWarningTitle: String {
        switch timerOnlyReason {
        case .noHRMax: return "Heart-rate zones unavailable"
        case .sensorFailed: return "Heart-rate session unavailable"
        case .noReadings: return "No heart-rate readings"
        }
    }

    var timerOnlyWarningMessage: String {
        switch timerOnlyReason {
        case .noHRMax:
            return "Heart rate can still be shown, but no HRmax estimate is available for target-zone coaching. Add a date of birth or recent heart-rate history in Apple Health."
        case .sensorFailed:
            return "The iPhone could not open a local workout sensor session. The timer and phases continue; reconnect Apple Watch or an external heart-rate source for live guidance."
        case .noReadings:
            return "The timer and phases continue, but no connected Apple Watch or external heart-rate source has produced a reading yet. Guidance starts automatically when readings arrive."
        }
    }

    private let healthKit: HealthKitManager
    private let recorder: N4x4WorkoutRecorder
    private let workout = PhoneWorkoutManager()
    private let haptics = N4x4HapticEngine()
    private let connectivity = N4x4ConnectivityManager()
    private let liveActivity = N4x4LiveActivityManager.shared

    private var engine: IntervalEngine?
    private var currentSnapshot: SessionSnapshot?
    private var sessionID: UUID?
    private var sessionCreatedAt: Date?
    private var sequence: UInt64 = 0
    private var failover: FailoverController?
    private var ticker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var graceCheck: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?
    private var pendingStartID: UUID?
    private var dateOfBirth: Date?
    private var receivedAnyHR = false
    private var localSensingStarted = false
    private var processedCommandIDs: Set<UUID> = []
    private var acknowledgedCommandIDs: [UUID] = []
    private var pendingMirrorCommands: [SessionCommand] = []
    private var stoppedSessionIDs: Set<UUID> = []

    private var mockHR: Double = 80
    private var useMockHR = false

    var liveFrames: [N4x4WorkoutFrame] { recorder.liveFrames }
    var lastCompletedLogID: UUID? { recorder.lastCompletedLogID }

    init(healthKit: HealthKitManager, store: LocalDataStore) {
        self.healthKit = healthKit
        self.recorder = N4x4WorkoutRecorder(context: store.context)
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

        // HealthKit workout mirroring is a second, background-capable transport.
        // Both transports may deliver the same payload; sequence/command IDs make
        // that safe and intentional.
        workout.onRemoteMessage = { [weak self] message in
            self?.handleRemoteMessage(message)
        }
        workout.onMirroredSessionDisconnect = { [weak self] _ in
            guard let self, self.isMirroring else { return }
            self.startWatchdogIfNeeded()
        }
        workout.onLocalSessionFailure = { [weak self] _ in
            self?.handleLocalSensorFailure()
        }
    }

    // MARK: - Lifecycle / start

    func onAppear(dateOfBirth: Date?) {
        self.dateOfBirth = dateOfBirth
    }

    func start(dateOfBirth: Date?) async {
        guard !isRunning, !isMirroring else { return }
        self.dateOfBirth = dateOfBirth

        let startID = UUID()
        pendingStartID = startID
        let observedMax = try? await healthKit.observedMaxHeartRate(days: 90)

        // An incoming Watch workout may have arrived while the query suspended.
        guard pendingStartID == startID, !isRunning, !isMirroring else { return }
        pendingStartID = nil

        let maxHR = HRMaxEstimator.estimate(
            dateOfBirth: dateOfBirth,
            observedMaxLast90d: observedMax
        )
        let now = Date()
        beginLocalAuthority(
            engine: IntervalEngine(hrMax: maxHR, startedAt: now),
            sessionID: UUID(),
            createdAt: now,
            startingSequence: 0,
            tryWatchHandoff: true
        )
    }

    private func beginLocalAuthority(
        engine: IntervalEngine,
        sessionID: UUID,
        createdAt: Date,
        startingSequence: UInt64,
        tryWatchHandoff: Bool,
        lastKnownHR: Double? = nil
    ) {
        let continuesExistingSession = self.sessionID == sessionID
        cancelRuntimeTasks()
        workout.stopLocal()

        if !continuesExistingSession {
            acknowledgedCommandIDs.removeAll(keepingCapacity: true)
            pendingMirrorCommands.removeAll(keepingCapacity: true)
        }

        self.engine = engine
        self.sessionID = sessionID
        sessionCreatedAt = createdAt
        sequence = startingSequence
        hrMax = engine.hrMax
        receivedAnyHR = false
        localSensingStarted = false
        heartRateSource = .none
        showTimerOnlyWarning = false
        // Taking over a running session must continue from its last heart
        // rate; restarting the simulated pulse at rest draws a false dip.
        mockHR = lastKnownHR ?? 80

        isMirroring = false
        isRunning = true
        haptics.prepare()

        recorder.begin(
            sessionID: sessionID,
            startedAt: createdAt,
            hrMax: engine.hrMax,
            details: workoutDetails
        )

        let result = engine.tick(at: Date())
        output = result.output
        publish(result.output)
        ticker = Task { [weak self, weak engine] in
            guard let engine else { return }
            await self?.runLoop(engine: engine, sessionID: sessionID)
        }

        if useMockHR {
            localSensingStarted = true
        } else if tryWatchHandoff, connectivity.isWatchAvailable {
            requestWatchOwnership(for: sessionID)
        } else {
            beginLocalSensing()
        }
    }

    /// The local engine keeps ticking while HealthKit launches the Watch. Only a
    /// real Watch snapshot causes the phone to yield, so launch failure or a
    /// connection race can never interrupt the protocol.
    private func requestWatchOwnership(for expectedSessionID: UUID) {
        handoffTask?.cancel()
        handoffTask = Task { [weak self] in
            guard let self else { return }
            let launched = await self.workout.startWatchApp()
            guard !Task.isCancelled,
                  self.isRunning,
                  self.sessionID == expectedSessionID else { return }

            if launched {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled,
                      self.isRunning,
                      self.sessionID == expectedSessionID else { return }
            }
            // Launch failure or no authoritative snapshot within the handoff
            // window: continue the already-running protocol with a phone source.
            self.beginLocalSensing()
        }
    }

    private func beginLocalSensing() {
        guard isRunning, !localSensingStarted, !useMockHR else { return }
        localSensingStarted = true

        let opened = workout.startLocal { [weak self] bpm, date in
            self?.ingest(bpm: bpm, at: date)
        }
        if !opened {
            localSensingStarted = false
            timerOnlyReason = .sensorFailed
            showTimerOnlyWarning = true
            scheduleLocalSensorRetry()
            return
        }

        if hrMax == nil {
            timerOnlyReason = .noHRMax
            showTimerOnlyWarning = true
        }
        scheduleHRArrivalCheck()
    }

    private func scheduleHRArrivalCheck() {
        graceCheck?.cancel()
        graceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self,
                  self.isRunning || self.isMirroring,
                  !self.useMockHR else { return }
            if !self.receivedAnyHR {
                self.timerOnlyReason = .noReadings
                self.showTimerOnlyWarning = true
            }
        }
    }

    private func handleLocalSensorFailure() {
        guard isRunning else { return }
        localSensingStarted = false
        receivedAnyHR = false
        heartRateSource = .none
        timerOnlyReason = .sensorFailed
        showTimerOnlyWarning = true
        scheduleLocalSensorRetry()
    }

    private func scheduleLocalSensorRetry() {
        graceCheck?.cancel()
        graceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.isRunning, !self.localSensingStarted else { return }
            self.beginLocalSensing()
        }
    }

    // MARK: - Remote state / failover

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

        // Duplicate snapshots received over WCSession and HealthKit still prove
        // the Watch is alive, even though they should not be rendered twice.
        if isMirroring,
           remote.sessionID == sessionID,
           remote.authority == .watch {
            failover?.receivedPrimaryTick(at: Date())
        }

        let localForConflict = (isRunning || isMirroring) ? currentSnapshot : nil
        guard SessionReconciliation.shouldAdopt(
            remote: remote,
            over: localForConflict,
            localDevice: .phone
        ) else {
            if isRunning, let currentSnapshot {
                broadcast(.snapshot(currentSnapshot))
            }
            return
        }

        // Opening a Watch app is not yet proof that its optical workout source
        // started. Keep (or assume) phone authority until HealthKit is ready; a
        // running protocol must never be abandoned into a sensorless handoff.
        if remote.authority == .watch,
           !remote.heartRateSessionActive,
           !remote.output.isFinished {
            handleUnavailableWatchAuthority(remote)
            return
        }

        adoptWatchSnapshot(remote)
    }

    private func handleUnavailableWatchAuthority(_ remote: SessionSnapshot) {
        if isMirroring, remote.sessionID == sessionID {
            currentSnapshot = remote
            output = remote.output
            promoteFromWatch()
            return
        }

        if isRunning {
            if let currentSnapshot { broadcast(.snapshot(currentSnapshot)) }
            return
        }

        let restored = IntervalEngine(
            checkpoint: remote.checkpoint,
            includeHeartRateHistory: false
        )
        beginLocalAuthority(
            engine: restored,
            sessionID: remote.sessionID,
            createdAt: remote.createdAt,
            startingSequence: remote.sequence,
            tryWatchHandoff: false,
            lastKnownHR: remote.output.trailingHR
        )
    }

    private func adoptWatchSnapshot(_ remote: SessionSnapshot) {
        guard remote.authority == .watch else { return }

        let wasFollowingThisSession = isMirroring && sessionID == remote.sessionID
        if sessionID != remote.sessionID {
            // A standalone Watch run has no phone-side equipment selection.
            // Do not accidentally reuse details from the previous phone run.
            workoutDetails = N4x4WorkoutDetails()
        }

        if sessionID != remote.sessionID {
            pendingMirrorCommands.removeAll(keepingCapacity: true)
        }
        pendingMirrorCommands.removeAll {
            remote.acknowledgedCommandIDs.contains($0.id)
        }
        acknowledgedCommandIDs = remote.acknowledgedCommandIDs
        processedCommandIDs.formUnion(remote.acknowledgedCommandIDs)

        ticker?.cancel(); ticker = nil
        handoffTask?.cancel(); handoffTask = nil
        if !wasFollowingThisSession {
            graceCheck?.cancel(); graceCheck = nil
        }
        workout.stopLocal()
        haptics.stop()
        engine = nil
        localSensingStarted = false
        receivedAnyHR = remote.heartRateSource == .watch && remote.output.trailingHR != nil

        sessionID = remote.sessionID
        sessionCreatedAt = remote.createdAt
        sequence = remote.sequence
        hrMax = remote.checkpoint.hrMax
        heartRateSource = remote.heartRateSource
        output = remote.output
        currentSnapshot = remote
        isRunning = false
        isMirroring = !remote.output.isFinished

        recorder.record(
            output: remote.output,
            sessionID: remote.sessionID,
            startedAt: remote.createdAt,
            hrMax: remote.checkpoint.hrMax,
            details: workoutDetails
        )

        if !remote.output.isFinished {
            if hrMax == nil {
                timerOnlyReason = .noHRMax
                showTimerOnlyWarning = true
            } else if remote.output.trailingHR != nil || !wasFollowingThisSession {
                showTimerOnlyWarning = false
            }
            if !wasFollowingThisSession { scheduleHRArrivalCheck() }
        }

        Task { await liveActivity.reconcile(remote) }

        if remote.output.isFinished {
            recorder.finish(
                output: remote.output,
                completed: true,
                healthKitRequested: remote.heartRateSessionActive
            )
            stoppedSessionIDs.insert(remote.sessionID)
            trimTerminalHistory()
            watchdog?.cancel(); watchdog = nil
            failover = nil
            workout.teardown()
        } else {
            failover = FailoverController(role: .mirror, referenceStart: Date())
            startWatchdogIfNeeded()
        }
    }

    private func startWatchdogIfNeeded() {
        guard isMirroring, watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isMirroring else { return }
                let now = Date()

                // Keep the visible clock moving between packets. This shadow
                // projection never owns sensors or haptics.
                if let checkpoint = self.currentSnapshot?.checkpoint {
                    let shadow = IntervalEngine(checkpoint: checkpoint)
                    self.output = shadow.tick(at: now).output
                }

                if self.failover?.evaluate(at: now) == true {
                    self.promoteFromWatch()
                    return
                }
            }
        }
    }

    private func promoteFromWatch() {
        guard isMirroring,
              let remote = currentSnapshot,
              !stoppedSessionIDs.contains(remote.sessionID),
              !remote.output.isFinished else { return }

        let restored = IntervalEngine(
            checkpoint: remote.checkpoint,
            includeHeartRateHistory: false
        )
        let commandsToReplay = pendingMirrorCommands
            .filter { $0.sessionID == remote.sessionID }
            .sorted { $0.issuedAt < $1.issuedAt }
        beginLocalAuthority(
            engine: restored,
            sessionID: remote.sessionID,
            createdAt: remote.createdAt,
            startingSequence: remote.sequence,
            tryWatchHandoff: false,
            lastKnownHR: remote.output.trailingHR
        )
        for command in commandsToReplay {
            remember(command.id)
            acknowledge(command.id)
            applyLocally(command.action, at: command.issuedAt)
        }
        pendingMirrorCommands.removeAll { $0.sessionID == remote.sessionID }
    }

    private func handleReachabilityChange(_ reachable: Bool) {
        guard let sessionID else { return }
        if reachable {
            if isRunning, let currentSnapshot {
                // A reappearing Watch receives the latest checkpoint plus the
                // ordered control log, then republishes wrist-sensor authority.
                broadcast(.snapshot(currentSnapshot))
                if connectivity.isWatchAvailable { requestWatchOwnership(for: sessionID) }
            } else if isMirroring {
                sendCommand(.requestSync)
            }
        } else if isMirroring {
            startWatchdogIfNeeded()
        }
    }

    // MARK: - User controls

    func pauseResume() {
        guard let output else { return }
        performUserAction(.setPaused(!output.isPaused))
    }

    @discardableResult
    func skip() -> Bool {
        guard canSkip else { return false }
        performUserAction(.skip)
        return true
    }

    var canSkip: Bool {
        (isRunning || isMirroring)
            && output?.phase.isSkippable == true
            && !(output?.isFinished ?? false)
    }

    private func performUserAction(_ action: SessionCommand.Action) {
        guard let sessionID else { return }
        let command = SessionCommand(sessionID: sessionID, action: action)

        if isRunning {
            remember(command.id)
            acknowledge(command.id)
            applyLocally(action, at: command.issuedAt)
            broadcast(.command(command))
            return
        }

        guard isMirroring else { return }
        pendingMirrorCommands.append(command)
        let sentLive = connectivity.send(.command(command))
        Task { [weak self] in
            guard let self else { return }
            let sentHealth = await self.workout.sendToRemote(.command(command))
            guard !sentLive, !sentHealth,
                  self.isMirroring,
                  self.sessionID == command.sessionID else { return }
            self.promoteFromWatch()
        }
    }

    func end() {
        guard let sessionID else { return }
        let shouldEndMirroredWorkout = isMirroring
        let command = SessionCommand(sessionID: sessionID, action: .stop)
        stoppedSessionIDs.insert(sessionID)
        trimTerminalHistory()
        broadcast(.command(command))
        if shouldEndMirroredWorkout { workout.endMirroredSession() }
        let finalSnapshot = currentSnapshot
        Task {
            await liveActivity.endExplicitly(
                sessionID: sessionID,
                finalSnapshot: finalSnapshot
            )
        }
        recorder.finish(output: output, completed: false, healthKitRequested: false)
        stopRuntime(clearOutput: true)
    }

    private func handleRemoteCommand(_ command: SessionCommand) {
        guard !processedCommandIDs.contains(command.id),
              !acknowledgedCommandIDs.contains(command.id) else { return }
        remember(command.id)

        if case .stop = command.action {
            stoppedSessionIDs.insert(command.sessionID)
            trimTerminalHistory()
            guard command.sessionID == sessionID else { return }
            Task {
                await liveActivity.endExplicitly(
                    sessionID: command.sessionID,
                    finalSnapshot: currentSnapshot
                )
            }
            recorder.finish(output: output, completed: false, healthKitRequested: false)
            stopRuntime(clearOutput: true)
            return
        }

        guard command.sessionID == sessionID,
              !stoppedSessionIDs.contains(command.sessionID) else { return }
        acknowledge(command.id)

        switch command.action {
        case .setPaused(let paused):
            if isRunning { applyLocally(.setPaused(paused), at: command.issuedAt) }
        case .skip:
            if isRunning { applyLocally(.skip, at: command.issuedAt) }
        case .requestSync:
            if isRunning, let currentSnapshot { broadcast(.snapshot(currentSnapshot)) }
        case .stop:
            break
        }
    }

    private func applyLocally(_ action: SessionCommand.Action, at now: Date = .now) {
        guard isRunning, let engine else { return }
        switch action {
        case .setPaused(let paused):
            engine.setPaused(paused, at: now)
        case .skip:
            _ = engine.skip(at: now)
        case .stop, .requestSync:
            return
        }
        let result = engine.tick(at: now)
        output = result.output
        publish(result.output)
    }

    private func sendCommand(_ action: SessionCommand.Action) {
        guard let sessionID else { return }
        broadcast(.command(SessionCommand(sessionID: sessionID, action: action)))
    }

    // MARK: - Engine loop / HR

    private func ingest(bpm: Double, at date: Date) {
        guard isRunning, let engine else { return }
        receivedAnyHR = true
        heartRateSource = .phoneExternal
        if timerOnlyReason == .noReadings || timerOnlyReason == .sensorFailed {
            showTimerOnlyWarning = false
        }
        engine.ingest(hrSample: bpm, at: date)
    }

    private func runLoop(engine: IntervalEngine, sessionID expectedSessionID: UUID) async {
        while !Task.isCancelled,
              isRunning,
              sessionID == expectedSessionID,
              self.engine === engine {
            let now = Date()
            if useMockHR, !engine.isPaused {
                let bpm = nextMockHR()
                engine.ingest(hrSample: bpm, at: now)
                receivedAnyHR = true
                heartRateSource = .phoneExternal
            }

            let result = engine.tick(at: now)
            output = result.output
            publish(result.output)
            for command in result.haptics { haptics.play(command) }

            if result.output.isFinished {
                finishLocalSession()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func publish(_ engineOutput: EngineOutput) {
        guard let engine, let sessionID, let createdAt = sessionCreatedAt else { return }
        sequence &+= 1
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            createdAt: createdAt,
            sequence: sequence,
            authority: .phone,
            heartRateSource: receivedAnyHR ? .phoneExternal : .none,
            heartRateSessionActive: localSensingStarted || useMockHR,
            acknowledgedCommandIDs: acknowledgedCommandIDs,
            output: engineOutput,
            checkpoint: engine.checkpoint()
        )
        currentSnapshot = snapshot
        heartRateSource = snapshot.heartRateSource
        recorder.record(
            output: engineOutput,
            sessionID: sessionID,
            startedAt: createdAt,
            hrMax: engine.hrMax,
            details: workoutDetails
        )
        broadcast(.snapshot(snapshot))
        Task { await liveActivity.reconcile(snapshot) }
    }

    private func broadcast(_ message: SessionMessage) {
        connectivity.send(message)
        workout.beginSendingToRemote(message)
    }

    private func finishLocalSession() {
        // The final snapshot was published before entering here. It ends the
        // Live Activity and lets a connected peer show completion as well.
        if let sessionID {
            stoppedSessionIDs.insert(sessionID)
            trimTerminalHistory()

            let requested = workout.completeLocalWorkout(
                at: .now,
                sessionID: sessionID,
                indoor: workoutDetails.equipment.isIndoor
            ) { [weak self] error in
                self?.recorder.updateHealthKitResult(sessionID: sessionID, error: error)
            }
            recorder.finish(
                output: output,
                completed: true,
                healthKitRequested: requested
            )
        }
        stopRuntime(clearOutput: false)
    }

    private func stopRuntime(clearOutput: Bool) {
        pendingStartID = nil
        cancelRuntimeTasks()
        workout.teardown()
        haptics.stop()
        engine = nil
        failover = nil
        isRunning = false
        isMirroring = false
        localSensingStarted = false
        receivedAnyHR = false
        heartRateSource = .none
        pendingMirrorCommands.removeAll(keepingCapacity: true)
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
        watchdog?.cancel(); watchdog = nil
        graceCheck?.cancel(); graceCheck = nil
        handoffTask?.cancel(); handoffTask = nil
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
            // Session UUIDs are only needed to reject reconnect traffic during
            // this process lifetime; cap memory without touching the current ID.
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
