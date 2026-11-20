import SwiftData
import XCTest
@testable import Longevity_Compass

@MainActor
final class SymptomTrackingTests: XCTestCase {
    /// Keeps the container alive; a context outlives its container only by crashing.
    private var container: ModelContainer?

    private func makeStore() throws -> LocalDataStore {
        let schema = Schema([SymptomEntry.self, DigestionTrackingPeriod.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        self.container = container
        return LocalDataStore(context: container.mainContext)
    }

    func testLevelsPerKindAndOrder() {
        XCTAssertEqual(SymptomKind.abdominalPain.levels, [.noticeable, .bothersome, .disruptedDay])
        XCTAssertEqual(SymptomKind.bloating.levels, [.mild, .severe])
        XCTAssertEqual(SymptomKind.diarrhoea.levels, [.loose, .watery])
        XCTAssertEqual(SymptomKind.gas.levels, [.present])
        XCTAssertEqual(SymptomKind.nausea.levels, [.mild, .severe])
        XCTAssertEqual(SymptomKind.heartburn.levels, [.mild, .severe])
        XCTAssertFalse(SymptomKind.gas.hasLevelChoice)
        XCTAssertEqual(SymptomKind.diarrhoea.label, "Diarrhoea")
        XCTAssertEqual(SymptomLevel.disruptedDay.label, "Disrupted my day")
        XCTAssertEqual(SymptomLevel.present.label, "More than usual")
    }

    func testRankAndTopLevel() {
        let low = SymptomEntry(onset: .now, kind: .abdominalPain, level: .noticeable)
        let top = SymptomEntry(onset: .now, kind: .abdominalPain, level: .disruptedDay)
        let gas = SymptomEntry(onset: .now, kind: .gas, level: .present)
        XCTAssertEqual(low.rank, 0)
        XCTAssertFalse(low.isTopLevel)
        XCTAssertEqual(top.rank, 2)
        XCTAssertTrue(top.isTopLevel)
        XCTAssertTrue(gas.isTopLevel)
    }

    func testStartStopTracking() throws {
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(store.activeTrackingPeriod())

        let first = store.startTracking(at: t0)
        let again = store.startTracking(at: t0.addingTimeInterval(10))
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(store.fetchTrackingPeriods().count, 1)

        let t1 = t0.addingTimeInterval(86_400)
        store.stopTracking(at: t1)
        XCTAssertNil(store.activeTrackingPeriod())
        XCTAssertEqual(first.end, t1)

        let second = store.startTracking(at: t1.addingTimeInterval(3600))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(store.fetchTrackingPeriods().count, 2)
        XCTAssertEqual(store.fetchTrackingPeriods().filter { $0.end == nil }.count, 1)
        XCTAssertEqual(store.activeTrackingPeriod()?.id, second.id)
    }

    func testOnsetChoices() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let start = now.addingTimeInterval(-10 * 3600)
        XCTAssertEqual(SymptomOnsetChoice.now.date(now: now, periodStart: start), now)
        XCTAssertEqual(SymptomOnsetChoice.oneHourAgo.date(now: now, periodStart: start), now.addingTimeInterval(-3600))
        XCTAssertEqual(SymptomOnsetChoice.threeHoursAgo.date(now: now, periodStart: start), now.addingTimeInterval(-3 * 3600))
        let custom = now.addingTimeInterval(-5 * 3600)
        XCTAssertEqual(SymptomOnsetChoice.earlier.date(now: now, periodStart: start, custom: custom), custom)
    }

    func testOnsetClampsToPeriodStartAndNow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let start = now.addingTimeInterval(-1800)
        XCTAssertEqual(SymptomOnsetChoice.oneHourAgo.date(now: now, periodStart: start), start)
        XCTAssertEqual(SymptomOnsetChoice.threeHoursAgo.date(now: now, periodStart: start), start)
        XCTAssertEqual(
            SymptomOnsetChoice.earlier.date(now: now, periodStart: start, custom: now.addingTimeInterval(500)),
            now
        )
    }

    func testInsertFetchDeleteSymptom() throws {
        let store = try makeStore()
        let older = SymptomEntry(onset: Date(timeIntervalSince1970: 100), kind: .nausea, level: .mild)
        let newer = SymptomEntry(onset: Date(timeIntervalSince1970: 200), kind: .bloating, level: .severe)
        store.insertSymptom(older)
        store.insertSymptom(newer)
        let fetched = store.fetchAllSymptoms()
        XCTAssertEqual(fetched.map(\.id), [newer.id, older.id])
        XCTAssertEqual(fetched.first?.kind, .bloating)
        XCTAssertEqual(fetched.first?.level, .severe)
        store.deleteSymptom(newer)
        XCTAssertEqual(store.fetchAllSymptoms().map(\.id), [older.id])
    }

    func testExportPayloadContainsSymptomsAndPeriods() throws {
        let store = try makeStore()
        store.startTracking(at: Date(timeIntervalSince1970: 100))
        store.insertSymptom(SymptomEntry(onset: Date(timeIntervalSince1970: 200), kind: .gas, level: .present))
        let payload = ExportService.makePayload(store: store)
        XCTAssertEqual(payload.symptomEntries.count, 1)
        XCTAssertEqual(payload.symptomEntries.first?.kind, "gas")
        XCTAssertEqual(payload.symptomEntries.first?.level, "present")
        XCTAssertEqual(payload.trackingPeriods.count, 1)
        XCTAssertNil(payload.trackingPeriods.first?.end)
    }

    func testDeleteAllLocalDataRemovesSymptomsAndPeriods() throws {
        let schema = Schema([
            ManualEntry.self, HealthMetricSnapshot.self, PriorityHistoryEntry.self,
            NutritionEntry.self, ExerciseDef.self, ExerciseEntry.self, N4x4WorkoutLog.self,
            BloodworkPanel.self, BloodworkMarker.self, SymptomEntry.self, DigestionTrackingPeriod.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let store = LocalDataStore(context: container.mainContext)
        store.startTracking(at: .now)
        store.insertSymptom(SymptomEntry(onset: .now, kind: .heartburn, level: .mild))
        store.deleteAllLocalData()
        XCTAssertTrue(store.fetchAllSymptoms().isEmpty)
        XCTAssertTrue(store.fetchTrackingPeriods().isEmpty)
    }
}
