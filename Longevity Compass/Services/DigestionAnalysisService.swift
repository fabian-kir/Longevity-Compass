import BackgroundTasks
import DigestionInsightsEngine
import Foundation
import Observation
import SwiftData

/// Seam for tests: the live engine, or a fake that returns canned results.
nonisolated protocol DigestionAnalysisEngine: Sendable {
    func run(_ input: AnalysisInput, progress: (@Sendable (Double) -> Void)?) async throws -> AnalysisResult
}

nonisolated struct LiveDigestionEngine: DigestionAnalysisEngine {
    @concurrent
    func run(_ input: AnalysisInput, progress: (@Sendable (Double) -> Void)?) async throws -> AnalysisResult {
        try await DigestionAnalysis.run(input, progress: progress)
    }
}

/// Builds the analysis input, runs the engine (off the main actor) with up to
/// three attempts, and stores runs (B11). Keeps the latest run and the last
/// run whose results may be shown.
@Observable
@MainActor
final class DigestionAnalysisService {
    private let store: LocalDataStore
    private let engine: DigestionAnalysisEngine
    private let now: () -> Date

    private(set) var isRunning = false
    /// 0…1 within the current attempt.
    private(set) var progress: Double = 0
    private(set) var currentAttempt = 0

    private(set) var latestRun: DigestionAnalysisRun?
    private(set) var lastGoodRun: DigestionAnalysisRun?
    private(set) var lastGoodInput: AnalysisInput?
    private(set) var lastGoodResult: AnalysisResult?
    private(set) var latestDiagnostics: RunDiagnostics?

    private var runTask: Task<Void, Never>?

    init(store: LocalDataStore, engine: DigestionAnalysisEngine = LiveDigestionEngine(), now: @escaping () -> Date = { .now }) {
        self.store = store
        self.engine = engine
        self.now = now
        reload()
    }

    // MARK: - Stored runs

    func reload() {
        let runs = store.fetchAnalysisRuns()
        latestRun = runs.first
        lastGoodRun = runs.first { $0.status.isShowable }
        lastGoodInput = lastGoodRun?.inputJSON.flatMap { Self.decode(AnalysisInput.self, from: $0) }
        lastGoodResult = lastGoodRun?.resultJSON.flatMap { Self.decode(AnalysisResult.self, from: $0) }
        latestDiagnostics = latestRun?.diagnosticsJSON.flatMap { Self.decode(RunDiagnostics.self, from: $0) }
    }

    // MARK: - Input

    /// Attempt-1 input with seed 0. Its fingerprint identifies the data.
    func buildInput() -> AnalysisInput {
        ExposureBuilder.build(
            nutrition: store.fetchAllNutritionEntries(),
            symptoms: store.fetchAllSymptoms(),
            periods: store.fetchTrackingPeriods(),
            now: now(),
            config: Self.config(attempt: 1, seed: 0)
        )
    }

    static func config(attempt: Int, seed: UInt64) -> AnalysisConfig {
        let settings = HealthThresholds.Digestion.attempts[attempt - 1]
        return AnalysisConfig(warmup: settings.warmup, targetAcceptance: settings.targetAcceptance, seed: seed)
    }

    /// B11: FNV-1a over the canonical input (seed 0) XOR attempt number.
    static func seed(fingerprint: UInt64, attempt: Int) -> UInt64 {
        fingerprint ^ UInt64(attempt)
    }

    // MARK: - Running

    /// Foreground run ("Run analysis now"). No-op while a run is in progress.
    func start() {
        guard !isRunning else { return }
        runTask = Task { await self.run() }
    }

    func cancel() {
        runTask?.cancel()
    }

    /// Runs attempts until one converges or all three are used. Resumes the
    /// attempt a cancelled run stopped at when the data are unchanged.
    /// Returns the final status; the run itself is `latestRun`.
    @discardableResult
    func run() async -> DigestionRunStatus? {
        guard !isRunning else { return nil }
        isRunning = true
        progress = 0
        defer {
            isRunning = false
            currentAttempt = 0
        }

        let base = buildInput()
        let fingerprint = DigestionAnalysis.fingerprint(base)
        let record: DigestionAnalysisRun
        var firstAttempt = 1
        if let latest = latestRun, latest.status == .cancelled, latest.fingerprintValue == fingerprint,
           (1...HealthThresholds.Digestion.attempts.count).contains(latest.attempts) {
            record = latest
            firstAttempt = latest.attempts
            record.startedAt = now()
            record.finishedAt = nil
            record.status = .running
        } else {
            record = DigestionAnalysisRun(startedAt: now(), inputFingerprint: fingerprint)
            store.insertAnalysisRun(record)
        }
        store.saveContext()
        latestRun = record

        for attempt in firstAttempt...HealthThresholds.Digestion.attempts.count {
            currentAttempt = attempt
            progress = 0
            var input = base
            input.config = Self.config(attempt: attempt, seed: Self.seed(fingerprint: fingerprint, attempt: attempt))
            record.attempts = attempt
            record.seed = String(input.config.seed)
            record.inputJSON = Self.encode(input)
            store.saveContext()

            let result: AnalysisResult
            do {
                result = try await engine.run(input) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.currentAttempt == attempt else { return }
                        self.progress = max(self.progress, value)
                    }
                }
            } catch is CancellationError {
                finish(record, status: .cancelled)
                return .cancelled
            } catch {
                finish(record, status: .failed)
                return .failed
            }

            record.resultJSON = Self.encode(result)
            record.diagnosticsJSON = Self.encode(result.diagnostics)
            switch result.status {
            case .notConverged where attempt < HealthThresholds.Digestion.attempts.count:
                store.saveContext()
                continue
            case .notConverged: finish(record, status: .notConverged)
            case .ok:           finish(record, status: .ok)
            case .insufficientData: finish(record, status: .insufficientData)
            case .cancelled:    finish(record, status: .cancelled)
            }
            return record.status
        }
        return record.status
    }

    private func finish(_ record: DigestionAnalysisRun, status: DigestionRunStatus) {
        // Deleted meanwhile ("Delete all local data").
        guard record.modelContext != nil, !record.isDeleted else { reload(); return }
        record.status = status
        record.finishedAt = now()
        // Keep this run and the newest showable one; drop the rest.
        let runs = store.fetchAnalysisRuns()
        let keepGood = status.isShowable ? record : runs.first { $0.status.isShowable && $0.id != record.id }
        for run in runs where run.id != record.id && run.id != keepGood?.id {
            store.deleteAnalysisRun(run)
        }
        store.saveContext()
        reload()
    }

    // MARK: - JSON

    /// Canonical form, same as the engine's fingerprint (sorted keys, seconds since 1970).
    nonisolated static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    nonisolated static func encode<T: Encodable>(_ value: T) -> String? {
        (try? encoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return json.data(using: .utf8).flatMap { try? decoder.decode(type, from: $0) }
    }
}

// MARK: - Nightly background run

/// `BGProcessingTask` for the nightly run (B11): external power, no network,
/// earliest next 02:00 local, only while tracking is active.
enum DigestionBackgroundTask {
    static let identifier = "FabianKirschenmann.Longevity-Compass.digestion-analysis"

    /// Call once during app launch, before launch finishes.
    static func register(services: AppServices) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in
                handle(task, services: services)
            }
        }
    }

    private static func handle(_ task: BGTask, services: AppServices) {
        guard services.isTrackingDigestion else {
            task.setTaskCompleted(success: true)
            return
        }
        let service = services.digestion
        let work = Task { await service.run() }
        task.expirationHandler = { work.cancel() }
        Task {
            let status = await work.value
            if status == .cancelled {
                schedule(earliest: Date.now.addingTimeInterval(HealthThresholds.Digestion.retryDelayMinutes * 60))
            } else {
                schedule()
            }
            task.setTaskCompleted(success: status != .failed)
        }
    }

    /// Submits (or replaces) the request. Fails quietly where background tasks
    /// are unavailable (simulator, Background App Refresh off).
    static func schedule(earliest: Date? = nil) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = earliest ?? nextRunDate(after: .now)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    /// Next `earliestRunHour`:00 local strictly after `date`.
    static func nextRunDate(after date: Date, calendar: Calendar = .current) -> Date {
        let components = DateComponents(hour: HealthThresholds.Digestion.earliestRunHour, minute: 0, second: 0)
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }
}
