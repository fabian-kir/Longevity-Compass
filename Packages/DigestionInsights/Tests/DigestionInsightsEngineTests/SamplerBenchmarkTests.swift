import XCTest
@testable import DigestionInsightsEngine

/// Heavy timing runs, skipped unless DIGESTION_HEAVY_TESTS=1.
/// Debug:   DIGESTION_HEAVY_TESTS=1 swift test --filter SamplerBenchmarkTests
/// Release: DIGESTION_HEAVY_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter SamplerBenchmarkTests
final class SamplerBenchmarkTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIGESTION_HEAVY_TESTS"] == "1", "heavy test")
    }

    func testStandardNormal2000Dimensions() async throws {
        let target = StandardNormalTarget(dimension: 2000)
        let configuration = NUTSConfiguration(chains: 4, warmup: 1000, samples: 1000, seed: 1)
        let start = Date()
        let output = try await NUTSSampler.sample(target, configuration: configuration)
        let samplingSeconds = Date().timeIntervalSince(start)
        let diagnosticsStart = Date()
        let diagnostics = SamplerDiagnostics(output)
        let diagnosticsSeconds = Date().timeIntervalSince(diagnosticsStart)
        print(String(
            format: "BENCH nuts-2000d sampling %.2f s, diagnostics %.2f s, leapfrogs %d, maxRhat %.4f, minBulkESS %.0f, step %.3f",
            samplingSeconds, diagnosticsSeconds, diagnostics.leapfrogSteps, diagnostics.maxRhat, diagnostics.minBulkESS,
            diagnostics.stepSizes[0]
        ))
        XCTAssertTrue(ConvergenceCriteria.default.isConverged(diagnostics))
    }
}
