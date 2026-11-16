#if canImport(ActivityKit) && os(iOS)
import XCTest
@testable import IntervalEngine

final class ActivityAttributesTests: XCTestCase {
    private let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testRunningContentStateUsesAbsoluteEndDates() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        let output = engine.tick(at: at(100)).output
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            createdAt: at(100),
            sequence: 1,
            authority: .watch,
            heartRateSource: .watch,
            output: output,
            checkpoint: engine.checkpoint()
        )

        let state = N4x4ActivityAttributes.ContentState(snapshot: snapshot, capturedAt: at(105))

        XCTAssertEqual(N4x4ActivityAttributes(snapshot: snapshot).sessionID, sessionID)
        XCTAssertEqual(state.phaseEndDate, at(185))
        XCTAssertEqual(state.totalEndDate, at(1_865))
        XCTAssertEqual(state.phaseRemaining, 80, accuracy: 0.001)
        XCTAssertEqual(state.totalRemaining, 1_760, accuracy: 0.001)
    }

    func testPausedContentStateUsesStaticRemainingValues() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        engine.pause(at: at(100))
        let output = engine.tick(at: at(500)).output
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            createdAt: at(500),
            sequence: 2,
            authority: .phone,
            heartRateSource: .phoneExternal,
            output: output,
            checkpoint: engine.checkpoint()
        )

        let state = N4x4ActivityAttributes.ContentState(snapshot: snapshot, capturedAt: at(500))

        XCTAssertNil(state.phaseEndDate)
        XCTAssertNil(state.totalEndDate)
        XCTAssertEqual(state.phaseRemaining, 80, accuracy: 0.001)
        XCTAssertTrue(state.isPaused)
    }
}
#endif
