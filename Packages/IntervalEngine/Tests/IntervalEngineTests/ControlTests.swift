import XCTest
@testable import IntervalEngine

final class ControlTests: XCTestCase {

    func testPauseFreezesTheClock() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        XCTAssertEqual(e.elapsed(at: at(100)), 100, accuracy: 0.001)
        e.pause(at: at(100))
        XCTAssertEqual(e.elapsed(at: at(130)), 100, accuracy: 0.001) // frozen
        XCTAssertTrue(e.isPaused)
    }

    func testResumeShiftsTheClockByPausedDuration() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.pause(at: at(100))
        e.resume(at: at(130)) // paused 30s
        XCTAssertFalse(e.isPaused)
        XCTAssertEqual(e.elapsed(at: at(130)), 100, accuracy: 0.001)
        XCTAssertEqual(e.elapsed(at: at(200)), 170, accuracy: 0.001)
    }

    func testDoublePauseIsIdempotent() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        e.pause(at: at(100))
        e.pause(at: at(110)) // ignored
        e.resume(at: at(120))
        XCTAssertEqual(e.elapsed(at: at(120)), 100, accuracy: 0.001) // only 20s removed
    }

    func testSkipWarmupJumpsToHighIntensity() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        _ = e.tick(at: at(10))
        XCTAssertEqual(e.tick(at: at(10)).output.phase, .warmUp)
        XCTAssertTrue(e.skip(at: at(10)))
        // Clock jumps to the warm-up boundary (180) → now in high 1.
        XCTAssertEqual(e.elapsed(at: at(10)), 180, accuracy: 0.001)
        XCTAssertEqual(e.tick(at: at(10)).output.phase, .highIntensity(round: 1))
    }

    func testSkipCooldownEndsSession() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        _ = e.tick(at: at(1700)) // cooldown (1680..1860)
        XCTAssertTrue(e.skip(at: at(1700)))
        XCTAssertTrue(e.tick(at: at(1700)).output.isFinished)
    }

    func testSkipDisallowedDuringHighIntensity() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        _ = e.tick(at: at(200)) // high 1
        XCTAssertFalse(e.skip(at: at(200)))
        XCTAssertEqual(e.tick(at: at(200)).output.phase, .highIntensity(round: 1))
    }

    func testProgressAndRemainingWithinPhase() {
        let e = IntervalEngine(hrMax: 190, startedAt: t0)
        // 90s into high 1 (180..420, 240s long): progress 90/240 = 0.375.
        let out = e.tick(at: at(270)).output
        XCTAssertEqual(out.phaseProgress, 0.375, accuracy: 0.001)
        XCTAssertEqual(out.timeRemainingInPhase, 150, accuracy: 0.001)
        XCTAssertEqual(out.totalRemaining, 1590, accuracy: 0.001)
    }
}
