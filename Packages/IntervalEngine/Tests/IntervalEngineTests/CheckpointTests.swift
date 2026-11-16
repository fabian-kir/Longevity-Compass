import XCTest
@testable import IntervalEngine

final class CheckpointTests: XCTestCase {
    func testPausedAndSkippedEngineRestoresExactly() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        engine.ingest(hrSample: 125, at: at(10))
        _ = engine.tick(at: at(10))
        XCTAssertTrue(engine.skip(at: at(10)))
        _ = engine.tick(at: at(20))
        engine.pause(at: at(25))

        let checkpoint = engine.checkpoint()
        let restored = IntervalEngine(checkpoint: checkpoint, includeHeartRateHistory: true)

        XCTAssertEqual(restored.checkpoint(), checkpoint)
        XCTAssertEqual(restored.elapsed(at: at(25)), 195, accuracy: 0.001)
        XCTAssertEqual(restored.tick(at: at(25)).output, engine.tick(at: at(25)).output)
    }

    func testRunningRestoreAdvancesAcrossOutage() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        _ = engine.tick(at: at(100))

        let restored = IntervalEngine(checkpoint: engine.checkpoint())

        XCTAssertEqual(restored.elapsed(at: at(160)), 160, accuracy: 0.001)
        XCTAssertEqual(restored.tick(at: at(160)).output.phase, .warmUp)
    }

    func testPausedRestoreDoesNotAdvanceAcrossOutageAndResumeAccountsForIt() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        engine.pause(at: at(100))

        let restored = IntervalEngine(checkpoint: engine.checkpoint())
        XCTAssertEqual(restored.elapsed(at: at(600)), 100, accuracy: 0.001)

        restored.resume(at: at(600))
        XCTAssertEqual(restored.elapsed(at: at(600)), 100, accuracy: 0.001)
        XCTAssertEqual(restored.elapsed(at: at(610)), 110, accuracy: 0.001)
    }

    func testSkipOffsetStillAdvancesFromSkippedTimelineAcrossOutage() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        _ = engine.tick(at: at(10))
        XCTAssertTrue(engine.skip(at: at(10)))

        let restored = IntervalEngine(checkpoint: engine.checkpoint())

        XCTAssertEqual(restored.elapsed(at: at(40)), 210, accuracy: 0.001)
        XCTAssertEqual(restored.tick(at: at(40)).output.phase, .highIntensity(round: 1))
    }

    func testRestoreCanClearHeartRateHistoryWithoutLosingRampOrTimeline() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        engine.feedConstantHR(120, from: 170, through: 180)
        _ = engine.tick(at: at(150))
        let rampStart = engine.tick(at: at(180)).output
        XCTAssertEqual(rampStart.target?.lowerBound ?? 0, 120, accuracy: 0.001)

        let checkpoint = engine.checkpoint()
        let restored = IntervalEngine(
            checkpoint: checkpoint,
            includeHeartRateHistory: false
        )

        XCTAssertFalse(checkpoint.heartRateSamples.isEmpty)
        XCTAssertTrue(restored.checkpoint().heartRateSamples.isEmpty)
        XCTAssertEqual(restored.checkpoint().startedAt, checkpoint.startedAt)
        XCTAssertEqual(restored.checkpoint().phaseStartHR, checkpoint.phaseStartHR)
        XCTAssertNil(restored.trailingHR(at: at(180)))
        XCTAssertEqual(restored.elapsed(at: at(210)), engine.elapsed(at: at(210)), accuracy: 0.001)
        XCTAssertEqual(
            restored.tick(at: at(210)).output.target?.lowerBound ?? 0,
            140.75,
            accuracy: 0.001
        )
    }

    func testGuidanceCadenceContinuesAfterRestore() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        engine.feedConstantHR(140, from: 285, through: 310)
        XCTAssertEqual(engine.tick(at: at(300)).haptics, [.goHarder])

        let restored = IntervalEngine(checkpoint: engine.checkpoint())

        XCTAssertTrue(restored.tick(at: at(305)).haptics.isEmpty)
        XCTAssertEqual(restored.tick(at: at(310)).haptics, [.goHarder])
    }

    func testFinishedCheckpointRemainsTerminal() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        XCTAssertTrue(engine.tick(at: at(1_860)).output.isFinished)
        XCTAssertTrue(engine.checkpoint().isFinished)

        let restored = IntervalEngine(checkpoint: engine.checkpoint())

        let restoredOutput = restored.tick(at: at(100)).output
        XCTAssertTrue(restoredOutput.isFinished)
        XCTAssertEqual(restoredOutput.elapsed, 1_860, accuracy: 0.001)
        XCTAssertTrue(restored.checkpoint().isFinished)
    }

    func testSetPausedCommandsAreIdempotent() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)

        engine.setPaused(true, at: at(100))
        engine.setPaused(true, at: at(120))
        XCTAssertTrue(engine.isPaused)

        engine.setPaused(false, at: at(130))
        engine.setPaused(false, at: at(140))
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(engine.elapsed(at: at(150)), 120, accuracy: 0.001)
    }
}
