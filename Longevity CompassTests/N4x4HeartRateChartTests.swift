import IntervalEngine
import XCTest
@testable import Longevity_Compass

final class N4x4HeartRateChartTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    /// One frame per listed second, with a heart-rate sample at each.
    private func frames(atSeconds seconds: [Int], bpm: Double = 120) -> [N4x4WorkoutFrame] {
        let engine = IntervalEngine(hrMax: 190, startedAt: start)
        return seconds.map { second in
            let date = start.addingTimeInterval(TimeInterval(second))
            engine.ingest(hrSample: bpm, at: date)
            return N4x4WorkoutFrame(capturedAt: date, output: engine.tick(at: date).output)
        }
    }

    func testContinuousFramesShareOneHeartRateSegment() {
        let points = N4x4HeartRateChart.plotPoints(for: frames(atSeconds: Array(0...30)))
        XCTAssertEqual(Set(points.map(\.heartRateSegment)), [0])
    }

    func testGapInElapsedTimeStartsNewHeartRateSegment() {
        // A stalled app produces no frames between 30 s and 120 s. The line
        // must break there instead of drawing a straight line across the gap.
        let points = N4x4HeartRateChart.plotPoints(
            for: frames(atSeconds: Array(0...30) + Array(120...140))
        )
        let before = points.filter { $0.frame.elapsed <= 30 }.map(\.heartRateSegment)
        let after = points.filter { $0.frame.elapsed >= 120 }.map(\.heartRateSegment)
        XCTAssertEqual(Set(before), [0])
        XCTAssertEqual(Set(after), [1])
    }

    func testTicksAreRoundTimesWithExactLabels() {
        // Live seven-minute window: two-minute steps, every label exact.
        let ticks = N4x4HeartRateChart.ticks(for: 20...440)
        XCTAssertEqual(ticks, [120, 240, 360])
        XCTAssertEqual(ticks.map(N4x4HeartRateChart.tickLabel), ["2m", "4m", "6m"])

        // First minute of a session: half-minute steps, no duplicate labels.
        let early = N4x4HeartRateChart.ticks(for: 0...60)
        XCTAssertEqual(early.map(N4x4HeartRateChart.tickLabel), ["0m", "0:30", "1m"])

        // Full 31-minute history chart stays at six labels or fewer.
        XCTAssertLessThanOrEqual(N4x4HeartRateChart.ticks(for: 0...1860).count, 6)
    }
}
