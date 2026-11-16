import IntervalEngine
import SwiftData
import XCTest
@testable import Longevity_Compass

@MainActor
final class N4x4WorkoutRecorderTests: XCTestCase {
    func testRecorderPersistsFramesAndSummary() throws {
        let schema = Schema([N4x4WorkoutLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let recorder = N4x4WorkoutRecorder(context: container.mainContext)
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let engine = IntervalEngine(hrMax: 190, startedAt: start)

        recorder.begin(
            sessionID: sessionID,
            startedAt: start,
            hrMax: 190,
            details: N4x4WorkoutDetails(equipment: .treadmill)
        )

        var finalOutput = engine.tick(at: start).output
        for second in stride(from: 0, through: 500, by: 5) {
            let date = start.addingTimeInterval(TimeInterval(second))
            let bpm: Double
            switch second {
            case 180...239: bpm = 120 + Double(second - 180) * (45.0 / 60.0)
            case 240...419: bpm = 165
            case 420...479: bpm = 165 - Double(second - 420) * (35.0 / 60.0)
            default: bpm = 120
            }
            engine.ingest(hrSample: bpm, at: date)
            finalOutput = engine.tick(at: date).output
            recorder.record(
                output: finalOutput,
                sessionID: sessionID,
                startedAt: start,
                hrMax: 190,
                details: N4x4WorkoutDetails(equipment: .treadmill),
                capturedAt: date
            )
        }
        recorder.finish(output: finalOutput, completed: true, healthKitRequested: true)

        let logs = try container.mainContext.fetch(FetchDescriptor<N4x4WorkoutLog>())
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.sessionID, sessionID)
        XCTAssertEqual(log.equipment, .treadmill)
        XCTAssertTrue(log.isCompleted)
        XCTAssertEqual(log.healthKitSaveState, .requested)
        XCTAssertGreaterThan(log.frames.count, 90)
        XCTAssertNotNil(log.averageHeartRate)
        XCTAssertNotNil(log.peakHeartRate)
        XCTAssertNotNil(log.targetAdherence)
        XCTAssertNotNil(log.averageOneMinuteRise)
        XCTAssertNotNil(log.averageOneMinuteRecovery)
    }

    func testFramePayloadRoundTripsThroughSwiftDataModel() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let engine = IntervalEngine(hrMax: 190, startedAt: start)
        engine.ingest(hrSample: 150, at: start.addingTimeInterval(200))
        let output = engine.tick(at: start.addingTimeInterval(200)).output
        let frame = N4x4WorkoutFrame(capturedAt: start, output: output)
        let log = N4x4WorkoutLog(
            sessionID: UUID(),
            startedAt: start,
            estimatedHRMax: 190,
            equipment: .stepper
        )

        log.frames = [frame]

        XCTAssertEqual(log.frames, [frame])
        XCTAssertEqual(log.equipment, .stepper)
    }
}

