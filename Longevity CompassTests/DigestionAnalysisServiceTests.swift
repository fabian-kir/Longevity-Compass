import DigestionInsightsEngine
import SwiftData
import XCTest
@testable import Longevity_Compass

/// Returns scripted statuses in order; `nil` in the script means "throw CancellationError".
private final class FakeEngine: DigestionAnalysisEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [AnalysisStatus?]
    private(set) var inputs: [AnalysisInput] = []

    init(_ script: [AnalysisStatus?]) { self.script = script }

    func setScript(_ script: [AnalysisStatus?]) {
        lock.withLock { self.script = script }
    }

    func run(_ input: AnalysisInput, progress: (@Sendable (Double) -> Void)?) async throws -> AnalysisResult {
        let next: AnalysisStatus? = lock.withLock {
            inputs.append(input)
            return script.isEmpty ? .ok : script.removeFirst()
        }
        progress?(0.5)
        guard let status = next else { throw CancellationError() }
        return AnalysisResult(
            status: status,
            diagnostics: RunDiagnostics(maxRhat: status == .ok ? 1.004 : 1.05, minBulkESS: 512, divergences: status == .ok ? 0 : 3, durationSeconds: 2, fits: 3),
            features: [],
            inputFingerprint: DigestionAnalysis.fingerprint(input)
        )
    }
}

@MainActor
final class DigestionAnalysisServiceTests: XCTestCase {
    /// Keeps the container alive; a context outlives its container only by crashing.
    private var container: ModelContainer?
    private let t0 = Date(timeIntervalSince1970: 1_767_225_600)
    private var clock: Date = Date(timeIntervalSince1970: 1_767_225_600 + 20 * 86_400)

    private func makeService(_ engine: FakeEngine) throws -> (DigestionAnalysisService, LocalDataStore) {
        let schema = Schema([NutritionEntry.self, SymptomEntry.self, DigestionTrackingPeriod.self, DigestionAnalysisRun.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        self.container = container
        let store = LocalDataStore(context: container.mainContext)
        store.startTracking(at: t0)
        let milk = IngredientProfile(
            origin: .openFoodFacts, allergens: [AllergenMark(allergen: .milk, source: .declared)], traces: [],
            ingredientIDs: [], unmatchedIngredientNames: [], freeFrom: []
        )
        for day in 0..<10 {
            store.insertNutritionEntry(NutritionEntry(
                date: t0.addingTimeInterval(Double(day) * 86_400 + 8 * 3600), source: .barcode, rawInput: "", ingredientProfile: milk
            ))
        }
        store.insertSymptom(SymptomEntry(onset: t0.addingTimeInterval(14 * 3600), kind: .diarrhoea, level: .loose))
        let service = DigestionAnalysisService(store: store, engine: engine, now: { [unowned self] in self.clock })
        return (service, store)
    }

    func testStableHashAndSeed() async throws {
        let engine = FakeEngine([.ok])
        let (service, store) = try makeService(engine)
        let a = service.buildInput()
        let b = service.buildInput()
        XCTAssertEqual(a, b)
        let fingerprint = DigestionAnalysis.fingerprint(a)
        XCTAssertEqual(DigestionAnalysisService.seed(fingerprint: fingerprint, attempt: 2), fingerprint ^ 2)

        await service.run()
        XCTAssertEqual(engine.inputs.first?.config.seed, fingerprint ^ 1)
        XCTAssertEqual(service.latestRun?.fingerprintValue, fingerprint)
        XCTAssertEqual(service.latestRun?.seedValue, fingerprint ^ 1)

        // New data, new fingerprint.
        store.insertSymptom(SymptomEntry(onset: t0.addingTimeInterval(86_400 + 15 * 3600), kind: .bloating, level: .mild))
        XCTAssertNotEqual(DigestionAnalysis.fingerprint(service.buildInput()), fingerprint)
    }

    func testAttemptEscalationOnNotConverged() async throws {
        let engine = FakeEngine([.notConverged, .notConverged, .ok])
        let (service, _) = try makeService(engine)
        let status = await service.run()
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(engine.inputs.map(\.config.warmup), [1000, 2000, 4000])
        XCTAssertEqual(engine.inputs.map(\.config.targetAcceptance), [0.8, 0.9, 0.95])
        let fingerprint = try XCTUnwrap(service.latestRun?.fingerprintValue)
        XCTAssertEqual(engine.inputs.map(\.config.seed), [fingerprint ^ 1, fingerprint ^ 2, fingerprint ^ 3])
        XCTAssertEqual(service.latestRun?.attempts, 3)
        XCTAssertNotNil(service.lastGoodResult)
        XCTAssertEqual(service.lastGoodInput?.config.warmup, 4000, "Stored input is the exact input of the converged attempt")
    }

    func testStopsAfterThreeAttempts() async throws {
        let engine = FakeEngine([.notConverged, .notConverged, .notConverged, .ok])
        let (service, _) = try makeService(engine)
        let status = await service.run()
        XCTAssertEqual(status, .notConverged)
        XCTAssertEqual(engine.inputs.count, 3)
        XCTAssertNil(service.lastGoodRun)
        XCTAssertEqual(service.latestDiagnostics?.divergences, 3)
    }

    func testLastGoodResultKept() async throws {
        let engine = FakeEngine([.ok])
        let (service, store) = try makeService(engine)
        await service.run()
        let good = try XCTUnwrap(service.lastGoodRun)

        clock = clock.addingTimeInterval(86_400)
        engine.setScript([.notConverged, .notConverged, .notConverged])
        await service.run()
        XCTAssertEqual(service.latestRun?.status, .notConverged)
        XCTAssertEqual(service.lastGoodRun?.id, good.id)
        XCTAssertNotNil(service.lastGoodResult)

        clock = clock.addingTimeInterval(86_400)
        engine.setScript([.notConverged, .notConverged, .notConverged])
        await service.run()
        XCTAssertEqual(store.fetchAnalysisRuns().count, 2, "Only latest run and last good run are kept")
        XCTAssertEqual(service.lastGoodRun?.id, good.id)
    }

    func testCancellationRecordedAndResumed() async throws {
        let engine = FakeEngine([.notConverged, nil])
        let (service, store) = try makeService(engine)
        let status = await service.run()
        XCTAssertEqual(status, .cancelled)
        XCTAssertEqual(service.latestRun?.status, .cancelled)
        XCTAssertEqual(service.latestRun?.attempts, 2)
        XCTAssertNotNil(service.latestRun?.finishedAt)
        XCTAssertFalse(service.isRunning)

        // Same data: the next run resumes at attempt 2 in the same record.
        engine.setScript([.ok])
        await service.run()
        XCTAssertEqual(engine.inputs.last?.config.warmup, 2000)
        XCTAssertEqual(service.latestRun?.status, .ok)
        XCTAssertEqual(store.fetchAnalysisRuns().count, 1)
    }

    func testNextRunDateIsNextTwoAM() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let evening = t0.addingTimeInterval(22 * 3600)
        XCTAssertEqual(DigestionBackgroundTask.nextRunDate(after: evening, calendar: cal), t0.addingTimeInterval(26 * 3600))
        let early = t0.addingTimeInterval(1 * 3600)
        XCTAssertEqual(DigestionBackgroundTask.nextRunDate(after: early, calendar: cal), t0.addingTimeInterval(2 * 3600))
    }
}
