import XCTest
@testable import IntervalEngine

/// hrMax 190 → high band [161.5, 180.5], recovery band [123.5, 133.0].
final class TargetLineTests: XCTestCase {

    private func engine() -> IntervalEngine {
        IntervalEngine(hrMax: 190, startedAt: t0)
    }

    private func target(_ e: IntervalEngine, at s: TimeInterval) -> ClosedRange<Double>? {
        e.tick(at: at(s)).output.target
    }

    func testWarmupHasNoTarget() {
        let e = engine()
        e.feedConstantHR(110, from: 0, through: 60)
        XCTAssertNil(target(e, at: 30))
    }

    func testHighIntensityRampsFromStartHRToLowerBandEdge() {
        let e = engine()
        // Warm-up HR ~120, so the ramp origin captured at the high-intensity
        // boundary (t=180) is 120.
        e.feedConstantHR(120, from: 160, through: 181)
        _ = e.tick(at: at(150))          // establish warm-up as previous phase
        let start = target(e, at: 180)   // transition into high 1, tInPhase 0
        XCTAssertEqual(start?.lowerBound ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(start?.upperBound ?? 0, 120, accuracy: 0.001)

        // Halfway through the 60s ramp: 120 + (161.5 - 120) * 0.5 = 140.75.
        let mid = target(e, at: 210)
        XCTAssertEqual(mid?.lowerBound ?? 0, 140.75, accuracy: 0.001)
        XCTAssertEqual(mid?.upperBound ?? 0, 140.75, accuracy: 0.001)
    }

    func testHighIntensityHoldsFullBandAfterRamp() {
        let e = engine()
        e.feedConstantHR(120, from: 160, through: 181)
        _ = e.tick(at: at(150))
        _ = e.tick(at: at(180))
        let band = target(e, at: 240) // tInPhase = 60 → ramp complete
        XCTAssertEqual(band?.lowerBound ?? 0, 161.5, accuracy: 0.001)
        XCTAssertEqual(band?.upperBound ?? 0, 180.5, accuracy: 0.001)
    }

    func testRecoveryRampsDownFromStartHRToUpperBandEdge() {
        let e = engine()
        // Drive through to the first recovery boundary (t=420) with a high HR.
        _ = e.tick(at: at(150))          // warm-up
        _ = e.tick(at: at(300))          // high 1
        e.feedConstantHR(175, from: 405, through: 421)
        let start = target(e, at: 420)   // transition into recovery 1
        XCTAssertEqual(start?.lowerBound ?? 0, 175, accuracy: 0.001)

        // Halfway: 175 + (133 - 175) * 0.5 = 154 (ramping DOWN toward the band).
        let mid = target(e, at: 450)
        XCTAssertEqual(mid?.lowerBound ?? 0, 154, accuracy: 0.001)

        let band = target(e, at: 480)    // ramp complete
        XCTAssertEqual(band?.lowerBound ?? 0, 123.5, accuracy: 0.001)
        XCTAssertEqual(band?.upperBound ?? 0, 133.0, accuracy: 0.001)
    }

    func testTimerOnlyModeHasNoTargetEvenInHighIntensity() {
        let e = IntervalEngine(hrMax: nil, startedAt: t0)
        e.feedConstantHR(150, from: 170, through: 320)
        _ = e.tick(at: at(150))
        XCTAssertNil(target(e, at: 300))
        XCTAssertEqual(e.tick(at: at(300)).output.deadBandState, .noTarget)
    }

    func testStartHRInsideBandProducesNoRamp() {
        let e = engine()
        // Enter high intensity already at 170 (inside [161.5, 180.5]).
        e.feedConstantHR(170, from: 160, through: 181)
        _ = e.tick(at: at(150))
        let start = target(e, at: 180) // captures ramp origin = 170
        XCTAssertEqual(start?.lowerBound ?? 0, 170, accuracy: 0.001) // clamped to self
        XCTAssertEqual(start?.upperBound ?? 0, 170, accuracy: 0.001)
        // Still 170 mid-ramp: the origin is already in-band, so no ramp occurs.
        let mid = target(e, at: 210)
        XCTAssertEqual(mid?.lowerBound ?? 0, 170, accuracy: 0.001)
    }
}
