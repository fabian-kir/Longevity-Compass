import XCTest
@testable import DigestionInsightsEngine

/// Diagnostics checked against values worked out by hand, so the convergence
/// gate (B9) rests on arithmetic a reader can redo.
final class DiagnosticsTests: XCTestCase {

    func testBasicRhatHandComputed() {
        // Chains [1,2,3,4] and [2,3,4,5]: n = 4, means 2.5 and 3.5.
        // B = n · var(means) = 4 · 0.5 = 2; W = var([1,2,3,4]) = 5/3.
        // R̂ = √((B/W + n − 1) / n) = √((1.2 + 3) / 4) = √1.05.
        let rhat = Diagnostics.basicRhat([[1, 2, 3, 4], [2, 3, 4, 5]])
        XCTAssertEqual(rhat, 1.05.squareRoot(), accuracy: 1e-12)
    }

    func testIdenticalChainsGiveRhatNearOne() {
        var rng = Xoshiro256StarStar(seed: 1)
        let chain = (0..<500).map { _ in rng.standardNormal() }
        let rhat = Diagnostics.splitRhat([chain, chain, chain, chain])
        // Identical chains carry no between-chain variance; split halves of
        // iid draws differ only by noise.
        XCTAssertEqual(rhat, 1, accuracy: 0.01)
    }

    func testShiftedChainsGiveRhatAboveThreshold() {
        var rng = Xoshiro256StarStar(seed: 2)
        let a = (0..<500).map { _ in rng.standardNormal() }
        let b = (0..<500).map { _ in rng.standardNormal() + 1 }
        XCTAssertGreaterThan(Diagnostics.splitRhat([a, b]), 1.01)
    }

    func testScaleDifferenceCaughtByFoldedRhat() {
        // Same location, different spread: bulk R̂ misses it, folded R̂ does not.
        var rng = Xoshiro256StarStar(seed: 3)
        let a = (0..<1000).map { _ in rng.standardNormal() }
        let b = (0..<1000).map { _ in 3 * rng.standardNormal() }
        XCTAssertGreaterThan(Diagnostics.splitRhat([a, b]), 1.01)
    }

    func testAverageRanksWithTies() {
        XCTAssertEqual(Diagnostics.averageRanks([3, 1, 3, 2]), [3.5, 1, 3.5, 2])
    }

    func testNormalQuantileKnownValues() {
        XCTAssertEqual(Diagnostics.normalQuantile(0.5), 0, accuracy: 1e-15)
        XCTAssertEqual(Diagnostics.normalQuantile(0.975), 1.959963984540054, accuracy: 1e-13)
        XCTAssertEqual(Diagnostics.normalQuantile(0.05), -1.6448536269514722, accuracy: 1e-13)
        XCTAssertEqual(Diagnostics.normalQuantile(1e-10), -6.361340902404056, accuracy: 1e-11)
    }

    func testQuantileType7() {
        XCTAssertEqual(Diagnostics.quantile([1, 2, 3, 4], 0.5), 2.5)
        XCTAssertEqual(Diagnostics.quantile([10, 20, 30], 0.25), 15)
    }

    func testEssHandComputedFixture() {
        // Two chains of 8. Lag-1 combined autocorrelation:
        //   meanVar = mean biased acov(0) · 8/7, varPlus = meanVar · 7/8 + var(chain means)
        //   ρ̂₁ = 1 − (meanVar − mean acov(1)) / varPlus = −0.26327
        // The pair (ρ̂₂, ρ̂₃) sums below zero, so the sequence stops at t = 2:
        //   τ = −1 + 2 · (1 + ρ̂₁) = 0.47347, below the floor 1/log10(16) = 0.83048,
        // so ESS = 16 · log10(16) = 19.26592.
        let chains: [[Double]] = [
            [0.3, -1.2, 0.8, 1.5, -0.4, 0.1, -0.9, 0.6],
            [1.1, 0.2, -0.5, -1.3, 0.9, 0.4, -0.2, -0.7],
        ]
        XCTAssertEqual(Diagnostics.essMean(chains), 16 * log10(16.0), accuracy: 1e-9)
    }

    func testEssOfAR1MatchesTheory() {
        // AR(1) with φ = 0.5: τ = (1 + φ)/(1 − φ) = 3, so ESS ≈ N / 3.
        var rng = Xoshiro256StarStar(seed: 4)
        let phi = 0.5
        let chains: [[Double]] = (0..<4).map { _ in
            var x = 0.0
            return (0..<5000).map { _ in
                x = phi * x + (1 - phi * phi).squareRoot() * rng.standardNormal()
                return x
            }
        }
        let ess = Diagnostics.essMean(chains)
        XCTAssertEqual(ess / 20_000, 1.0 / 3, accuracy: 0.05)
        let bulk = Diagnostics.bulkESS(chains)
        XCTAssertEqual(bulk / 20_000, 1.0 / 3, accuracy: 0.05)
        XCTAssertGreaterThan(Diagnostics.tailESS(chains), 1000)
    }

    func testIidDrawsHaveEssNearSampleSize() {
        var rng = Xoshiro256StarStar(seed: 5)
        let chains: [[Double]] = (0..<4).map { _ in (0..<1000).map { _ in rng.standardNormal() } }
        XCTAssertEqual(Diagnostics.bulkESS(chains) / 4000, 1, accuracy: 0.15)
    }

    func testConvergenceCriteria() {
        let criteria = ConvergenceCriteria.default
        XCTAssertTrue(criteria.isConverged(maxRhat: 1.005, minBulkESS: 400, divergences: 0))
        XCTAssertFalse(criteria.isConverged(maxRhat: 1.01, minBulkESS: 900, divergences: 0))
        XCTAssertFalse(criteria.isConverged(maxRhat: 1.0, minBulkESS: 399, divergences: 0))
        XCTAssertFalse(criteria.isConverged(maxRhat: 1.0, minBulkESS: 900, divergences: 1))
        XCTAssertFalse(criteria.isConverged(maxRhat: .nan, minBulkESS: 900, divergences: 0))
    }
}
