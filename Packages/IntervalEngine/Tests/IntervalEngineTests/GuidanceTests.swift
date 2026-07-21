import XCTest
@testable import IntervalEngine

final class GuidanceTests: XCTestCase {

    // MARK: - Trailing average (spec §4)

    func testTrailingAverageOnlyCountsLast10Seconds() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.ingest(hrSample: 100, at: at(0))   // outside window at now=15
        e.ingest(hrSample: 120, at: at(8))   // inside [5,15]
        e.ingest(hrSample: 140, at: at(12))  // inside
        XCTAssertEqual(e.trailingHR(at: at(15))!, 130, accuracy: 0.001)
    }

    func testTrailingAverageNilWhenWindowEmpty() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.ingest(hrSample: 120, at: at(0))
        XCTAssertNil(e.trailingHR(at: at(20)))
    }

    // MARK: - Repeat-rate scaling (spec §4)

    func testGuidanceIntervalScaling() {
        XCTAssertEqual(IntervalEngine.guidanceInterval(distanceOutside: 0), 20, accuracy: 0.001)
        XCTAssertEqual(IntervalEngine.guidanceInterval(distanceOutside: 10), 12.5, accuracy: 0.001)
        XCTAssertEqual(IntervalEngine.guidanceInterval(distanceOutside: 20), 5, accuracy: 0.001)
        XCTAssertEqual(IntervalEngine.guidanceInterval(distanceOutside: 40), 5, accuracy: 0.001) // floor holds
        XCTAssertEqual(IntervalEngine.guidanceInterval(distanceOutside: -5), 20, accuracy: 0.001) // clamps
    }

    // MARK: - Dead-band (spec §4)

    /// High band [161.5,180.5]; dead-band edges 153.5 / 188.5.
    func testDeadBandStates() {
        func stateAt(hr: Double) -> DeadBandState {
            let e = IntervalEngine(hrMax: 190, startedAt: t0)
            e.feedConstantHR(hr, from: 285, through: 305)
            return e.tick(at: at(300)).output.deadBandState // deep in high 1, past ramp
        }
        XCTAssertEqual(stateAt(hr: 170), .inRange)  // inside band
        XCTAssertEqual(stateAt(hr: 155), .inRange)  // inside dead-band below band
        XCTAssertEqual(stateAt(hr: 150), .below)    // beyond dead-band
        XCTAssertEqual(stateAt(hr: 185), .inRange)  // inside dead-band above band
        XCTAssertEqual(stateAt(hr: 195), .above)    // beyond dead-band
    }

    func testInRangeFiresNoHaptic() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.feedConstantHR(170, from: 285, through: 305)
        XCTAssertTrue(e.tick(at: at(300)).haptics.isEmpty)
    }

    // MARK: - Guidance haptic cadence

    func testGoHarderRepeatsOnScaledInterval() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        // HR 140 → below dead-band (153.5). distance 13.5 → interval ≈ 9.875s.
        // Feed only through the last tick: the 30s buffer retention is relative to
        // the newest sample, so feeding far past t=310 would prune the t=300 window.
        e.feedConstantHR(140, from: 285, through: 310)

        XCTAssertEqual(e.tick(at: at(300)).haptics, [.goHarder]) // first crossing fires immediately
        XCTAssertTrue(e.tick(at: at(305)).haptics.isEmpty)        // 5s < 9.875 → not due
        XCTAssertEqual(e.tick(at: at(310)).haptics, [.goHarder])  // 10s ≥ 9.875 → due
    }

    func testChillFiresWhenAboveBand() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.feedConstantHR(200, from: 285, through: 305) // above dead-band (188.5)
        XCTAssertEqual(e.tick(at: at(300)).haptics, [.chill])
    }

    func testSwitchingSidesBypassesTheRepeatInterval() {
        // Both sides sit just 0.5 bpm outside the dead-band → ~19.6s interval.
        // The flip happens 11s later, which the interval alone would suppress —
        // it only fires because the side changed (spec §4). A full 10s window of
        // the new value is fed first, since the trailing average can't teleport.
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.feedConstantHR(153, from: 285, through: 300) // just below (edge 153.5)
        XCTAssertEqual(e.tick(at: at(300)).haptics, [.goHarder])
        e.feedConstantHR(189, from: 301, through: 311) // just above (edge 188.5)
        XCTAssertEqual(e.tick(at: at(311)).haptics, [.chill]) // 11s < 19.6s, fires on side flip
    }

    func testReturningInRangeThenLeavingFiresImmediately() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.feedConstantHR(140, from: 285, through: 300)
        XCTAssertEqual(e.tick(at: at(300)).haptics, [.goHarder])
        e.feedConstantHR(170, from: 301, through: 315) // full window back in range
        XCTAssertTrue(e.tick(at: at(315)).haptics.isEmpty) // clears guidance state
        e.feedConstantHR(140, from: 316, through: 330) // out again
        XCTAssertEqual(e.tick(at: at(330)).haptics, [.goHarder]) // re-fires immediately
    }

    // MARK: - Phase transition (spec §4)

    func testPhaseTransitionFiresOncePerBoundaryNotOnFirstTick() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.feedConstantHR(150, from: 0, through: 320)
        XCTAssertFalse(e.tick(at: at(10)).haptics.contains(.phaseTransition))  // first tick: none
        XCTAssertTrue(e.tick(at: at(185)).haptics.contains(.phaseTransition))  // warm-up → high 1
        XCTAssertFalse(e.tick(at: at(190)).haptics.contains(.phaseTransition)) // same phase
    }

    func testTimerOnlyStillFiresPhaseTransition() {
        let e = IntervalEngine(hrMax: nil, startedAt: t0)
        _ = e.tick(at: at(10))
        XCTAssertEqual(e.tick(at: at(185)).haptics, [.phaseTransition])
    }
}
