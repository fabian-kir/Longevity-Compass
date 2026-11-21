import XCTest
@testable import DigestionInsightsEngine

/// Level rules (B9) on handcrafted summaries. The rule tests use fixed,
/// distinct thresholds (unit 3's placeholders) so that clear, early and half
/// conditions can be told apart; the calibrated defaults are checked separately.
final class ClassificationTests: XCTestCase {

    private let config = AnalysisConfig(seed: 0, thresholds: Thresholds(earlyProb: 0.90, clearProb: 0.98, halfProb: 0.90))

    private func summary(probRaises: Double, averageRR: Interval = Interval(median: 1, lower: 0.9, upper: 1.1), peak: Double = 1.1) -> EffectSummary {
        EffectSummary(
            peakRR: Interval(median: peak, lower: 1, upper: peak + 0.3),
            averageRR: averageRR,
            excessPerExposure: Interval(median: 0, lower: -0.1, upper: 0.1),
            medianLagHours: nil,
            probRaises: probRaises,
            probPeakAbove: 0
        )
    }

    private func level(
        exposures: Int = 30, symptomsAfter: Int = 10, _ overall: EffectSummary?,
        first: Double? = nil, second: Double? = nil
    ) -> PatternLevel {
        PatternLevel.classify(
            exposureCount: exposures, symptomsAfterCount: symptomsAfter, overall: overall,
            firstHalfProbRaises: first, secondHalfProbRaises: second, config: config
        )
    }

    /// Calibrated by unit 4 (Simulation/results.md); `digestion-sim report`
    /// also fails when these differ from results.json.
    func testCalibratedDefaultThresholds() {
        XCTAssertEqual(Thresholds.default.earlyProb, 0.80)
        XCTAssertEqual(Thresholds.default.clearProb, 0.80)
        XCTAssertEqual(Thresholds.default.halfProb, 0.80)
        XCTAssertEqual(Thresholds.default.noLinkMinExposures, 15)
        XCTAssertEqual(Thresholds.default.noLinkLower, 0.8)
        XCTAssertEqual(Thresholds.default.noLinkUpper, 1.25)
    }

    func testNotEnoughData() {
        XCTAssertEqual(level(exposures: 4, summary(probRaises: 0.99), first: 0.99, second: 0.99), .notEnoughData)
        XCTAssertEqual(level(symptomsAfter: 2, summary(probRaises: 0.99), first: 0.99, second: 0.99), .notEnoughData)
        XCTAssertEqual(level(nil), .notEnoughData)
    }

    func testClearPatternNeedsBothHalves() {
        XCTAssertEqual(level(summary(probRaises: 0.985), first: 0.95, second: 0.91), .clearPattern)
        XCTAssertEqual(level(summary(probRaises: 0.985), first: 0.95, second: 0.85), .earlySignal)
        XCTAssertEqual(level(summary(probRaises: 0.985), first: nil, second: 0.95), .earlySignal)
        XCTAssertEqual(level(summary(probRaises: 0.97), first: 0.99, second: 0.99), .earlySignal)
    }

    func testEarlySignal() {
        XCTAssertEqual(level(summary(probRaises: 0.90)), .earlySignal)
        XCTAssertEqual(level(summary(probRaises: 0.89)), .noLinkFound)
    }

    func testNoLinkFound() {
        let tight = Interval(median: 1, lower: 0.85, upper: 1.2)
        XCTAssertEqual(level(exposures: 15, summary(probRaises: 0.5, averageRR: tight)), .noLinkFound)
        XCTAssertEqual(level(exposures: 14, summary(probRaises: 0.5, averageRR: tight)), .inconclusive)
        XCTAssertEqual(level(summary(probRaises: 0.5, averageRR: Interval(median: 1, lower: 0.75, upper: 1.2))), .inconclusive)
        XCTAssertEqual(level(summary(probRaises: 0.5, averageRR: Interval(median: 1, lower: 0.85, upper: 1.3))), .inconclusive)
    }

    func testNoLinkFoundRefusedWhenPeakIsHigh() {
        // A ×3 effect over a few hours averages out over 96 h; it must not read
        // as "No link found".
        let tight = Interval(median: 1.05, lower: 0.95, upper: 1.15)
        XCTAssertEqual(level(summary(probRaises: 0.6, averageRR: tight, peak: 2.5)), .inconclusive)
    }
}
