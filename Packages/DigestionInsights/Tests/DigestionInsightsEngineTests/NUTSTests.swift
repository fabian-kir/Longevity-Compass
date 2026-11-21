import XCTest
@testable import DigestionInsightsEngine

/// Exact-answer targets (B12): the sampler must recover known means and
/// variances within Monte-Carlo error, deterministically, and stop on cancel.
final class NUTSTests: XCTestCase {

    /// Asserts mean and variance of `parameter` within `k` Monte-Carlo
    /// standard errors, using bulk ESS for the effective sample size.
    private func assertMoments(
        _ output: SamplerOutput,
        parameter: Int,
        mean expectedMean: Double,
        variance expectedVariance: Double,
        k: Double = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let traces = output.traces(of: parameter)
        let pooled = traces.flatMap { $0 }
        let n = Double(pooled.count)
        let mean = pooled.reduce(0, +) / n
        let variance = pooled.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
        let ess = Diagnostics.bulkESS(traces)
        // SE(mean) = σ/√ESS; SE(variance) ≈ σ²·√(2/ESS) for normal marginals.
        let meanTolerance = k * expectedVariance.squareRoot() / ess.squareRoot()
        let varianceTolerance = k * expectedVariance * (2 / ess).squareRoot()
        XCTAssertEqual(mean, expectedMean, accuracy: meanTolerance, "mean of parameter \(parameter)", file: file, line: line)
        XCTAssertEqual(variance, expectedVariance, accuracy: varianceTolerance, "variance of parameter \(parameter)", file: file, line: line)
    }

    private func config(seed: UInt64, warmup: Int = 500, samples: Int = 1000) -> NUTSConfiguration {
        NUTSConfiguration(chains: 4, warmup: warmup, samples: samples, seed: seed)
    }

    func testOneDimensionalStandardNormal() async throws {
        let output = try await NUTSSampler.sample(StandardNormalTarget(dimension: 1), configuration: config(seed: 1))
        assertMoments(output, parameter: 0, mean: 0, variance: 1)
        let diagnostics = SamplerDiagnostics(output)
        XCTAssertTrue(ConvergenceCriteria.default.isConverged(diagnostics), "\(diagnostics)")
    }

    func testHundredDimensionalStandardNormal() async throws {
        let output = try await NUTSSampler.sample(StandardNormalTarget(dimension: 100), configuration: config(seed: 2))
        for parameter in [0, 17, 50, 99] {
            assertMoments(output, parameter: parameter, mean: 0, variance: 1)
        }
        // Across all 100 coordinates the average of the per-coordinate
        // variances is a much tighter check.
        var totalVariance = 0.0
        for parameter in 0..<100 {
            let pooled = output.traces(of: parameter).flatMap { $0 }
            let mean = pooled.reduce(0, +) / Double(pooled.count)
            totalVariance += pooled.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(pooled.count - 1)
        }
        XCTAssertEqual(totalVariance / 100, 1, accuracy: 0.03)
        let diagnostics = SamplerDiagnostics(output)
        XCTAssertTrue(ConvergenceCriteria.default.isConverged(diagnostics), "\(diagnostics.maxRhat) \(diagnostics.minBulkESS)")
        XCTAssertEqual(diagnostics.divergences, 0)
        XCTAssertEqual(diagnostics.stepSizes.count, 4)
    }

    func testCorrelatedTwoDimensionalNormal() async throws {
        let rho = 0.9
        let output = try await NUTSSampler.sample(CorrelatedNormal2DTarget(rho: rho), configuration: config(seed: 3))
        assertMoments(output, parameter: 0, mean: 0, variance: 1)
        assertMoments(output, parameter: 1, mean: 0, variance: 1)
        let x = output.traces(of: 0).flatMap { $0 }
        let y = output.traces(of: 1).flatMap { $0 }
        let covariance = zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } / Double(x.count)
        XCTAssertEqual(covariance, rho, accuracy: 0.05)
    }

    func testNonCentredFunnel() async throws {
        let output = try await NUTSSampler.sample(NonCentredFunnelTarget(dimension: 10), configuration: config(seed: 4))
        assertMoments(output, parameter: 0, mean: 0, variance: 9)
        for parameter in 1..<10 {
            assertMoments(output, parameter: parameter, mean: 0, variance: 1)
        }
        XCTAssertEqual(output.divergences, 0)
    }

    func testMassMatrixAdaptsToScales() async throws {
        // Variances from 1e-4 to 1e4: without metric adaptation the step size
        // would collapse to the smallest scale and the largest would not mix.
        let variances = [1e-4, 1e-2, 1, 1e2, 1e4]
        let output = try await NUTSSampler.sample(ScaledNormalTarget(variances: variances), configuration: config(seed: 6))
        for (index, variance) in variances.enumerated() {
            assertMoments(output, parameter: index, mean: 0, variance: variance)
            for chain in output.chains {
                // Adapted inverse metric estimates the posterior variance.
                XCTAssertEqual(log(chain.inverseMetric[index] / variance), 0, accuracy: 0.5)
            }
        }
        let meanAccept = output.chains.flatMap(\.acceptStat).reduce(0, +) / 4000
        // Realised acceptance sits above the 0.8 target in low dimensions
        // (averaged step size is smaller than the last iterates).
        XCTAssertTrue((0.7...0.97).contains(meanAccept), "\(meanAccept)")
    }

    func testSameSeedGivesBitwiseIdenticalOutput() async throws {
        let target = CorrelatedNormal2DTarget(rho: 0.5)
        let first = try await NUTSSampler.sample(target, configuration: config(seed: 9, warmup: 200, samples: 200))
        let second = try await NUTSSampler.sample(target, configuration: config(seed: 9, warmup: 200, samples: 200))
        XCTAssertEqual(first, second)
        let other = try await NUTSSampler.sample(target, configuration: config(seed: 10, warmup: 200, samples: 200))
        XCTAssertNotEqual(first.chains[0].draws, other.chains[0].draws)
        XCTAssertNotEqual(first.chains[0].draws, first.chains[1].draws, "chains must use independent streams")
    }

    func testParallelChainsMatchSingleChainRuns() async throws {
        // Parallel scheduling must not change any chain.
        let target = StandardNormalTarget(dimension: 5)
        let configuration = config(seed: 21, warmup: 100, samples: 100)
        let parallel = try await NUTSSampler.sample(target, configuration: configuration)
        for chain in 0..<configuration.chains {
            let single = try NUTSSampler.sampleChain(target, configuration: configuration, chainIndex: chain)
            XCTAssertEqual(single, parallel.chains[chain])
        }
    }

    func testCancellationThrowsCancellationError() async throws {
        let target = StandardNormalTarget(dimension: 500)
        let configuration = NUTSConfiguration(chains: 4, warmup: 100_000, samples: 100_000, seed: 1)
        let task = Task { try await NUTSSampler.sample(target, configuration: configuration) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testIterationCallbackCountsEveryIteration() async throws {
        let counter = Counter()
        let configuration = config(seed: 5, warmup: 50, samples: 30)
        _ = try await NUTSSampler.sample(StandardNormalTarget(dimension: 2), configuration: configuration) {
            counter.increment()
        }
        XCTAssertEqual(counter.value, 4 * 80)
    }

    func testInvalidConfigurationRejected() async {
        do {
            _ = try await NUTSSampler.sample(
                StandardNormalTarget(dimension: 2),
                configuration: NUTSConfiguration(chains: 0, seed: 1)
            )
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error is SamplerError)
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Independent normals with the given variances.
struct ScaledNormalTarget: LogDensityTarget {
    let variances: [Double]
    var dimension: Int { variances.count }

    func logDensity(
        _ position: UnsafeBufferPointer<Double>,
        gradient: UnsafeMutableBufferPointer<Double>,
        workspace: inout Void
    ) -> Double {
        var logp = 0.0
        for i in 0..<dimension {
            logp -= 0.5 * position[i] * position[i] / variances[i]
            gradient[i] = -position[i] / variances[i]
        }
        return logp
    }
}
