import XCTest
@testable import DigestionInsightsEngine

/// Per-draw curve statistics (B9 definitions) on curves with known answers.
final class SummaryTests: XCTestCase {

    private func stats(_ beta: [Double], baseline: Double = 0.01) -> PosteriorSummary.CurveStats {
        let rr = beta.map { exp($0) }
        return beta.withUnsafeBufferPointer { b in
            rr.withUnsafeBufferPointer { r in
                PosteriorSummary.curveStats(logRR: b.baseAddress!, rr: r.baseAddress!, count: beta.count, baselineRate: baseline)
            }
        }
    }

    func testFlatDoublingCurve() {
        let s = stats([Double](repeating: log(2), count: 96), baseline: 0.01)
        XCTAssertEqual(s.peakRR, 2, accuracy: 1e-12)
        XCTAssertEqual(s.averageRR, 2, accuracy: 1e-12)
        XCTAssertEqual(s.excess, 0.01 * 96, accuracy: 1e-12)
        XCTAssertEqual(s.sum, 96 * log(2), accuracy: 1e-12)
        // Uniform positive excess: half reached at 48 h.
        XCTAssertEqual(s.medianLag!, 48, accuracy: 1e-12)
    }

    func testAcuteBump() {
        // RR 3 in lag hours 4..7: positive excess 2 per hour, total 8; half (4)
        // is reached halfway through hour 5 → 5.0 + (4 − 2)/2 = 6.0.
        var beta = [Double](repeating: 0, count: 96)
        for l in 4...7 { beta[l] = log(3) }
        let s = stats(beta, baseline: 0.02)
        XCTAssertEqual(s.peakRR, 3, accuracy: 1e-12)
        XCTAssertEqual(s.averageRR, exp(4 * log(3) / 96), accuracy: 1e-12)
        XCTAssertEqual(s.excess, 0.02 * 8, accuracy: 1e-12)
        XCTAssertEqual(s.medianLag!, 6, accuracy: 1e-12)
        XCTAssertGreaterThan(s.sum, 0)
    }

    func testProtectiveCurveHasNoMedianLag() {
        let s = stats([Double](repeating: -0.2, count: 96))
        XCTAssertNil(s.medianLag)
        XCTAssertLessThan(s.sum, 0)
        XCTAssertLessThan(s.excess, 0)
    }

    func testEffectSummaryProbabilities() {
        let raising = stats([Double](repeating: log(1.5), count: 96))
        let lowering = stats([Double](repeating: log(0.9), count: 96))
        let summary = PosteriorSummary.effectSummary([raising, raising, raising, lowering], peakThreshold: 1.25)
        XCTAssertEqual(summary.probRaises, 0.75)
        XCTAssertEqual(summary.probPeakAbove, 0.75)
        XCTAssertNotNil(summary.medianLagHours)
        XCTAssertEqual(summary.peakRR.median, 1.5, accuracy: 1e-12)
    }

    func testIntervalUsesFiveAndNinetyFivePercentQuantiles() {
        let values = (0...100).map(Double.init)
        let interval = PosteriorSummary.interval(values.reversed())
        XCTAssertEqual(interval.median, 50)
        XCTAssertEqual(interval.lower, 5)
        XCTAssertEqual(interval.upper, 95)
    }

    func testLagMatrixUsesHourMidpoints() {
        let basis = BSplineBasis(lower: 0, upper: 96, interiorKnots: [3, 8, 24, 48])
        let matrix = PosteriorSummary.lagMatrix(basis, maxLagHours: 96)
        XCTAssertEqual(Array(matrix[(10 * 8)..<(11 * 8)]), basis.evaluate(at: 10.5))
    }
}
