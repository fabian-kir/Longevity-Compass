import XCTest
@testable import DigestionInsightsEngine

/// Reference workload (unit 3 prompt): 180 days, 3 meals/day, 40 eligible
/// features, 6 kinds, default sampler settings, three fits. Skipped unless
/// DIGESTION_HEAVY_TESTS=1.
/// Debug:   DIGESTION_HEAVY_TESTS=1 swift test --filter AnalysisBenchmarkTests
/// Release: DIGESTION_HEAVY_TESTS=1 swift test -c release -Xswiftc -enable-testing --filter AnalysisBenchmarkTests
/// B11 attempts: DIGESTION_BENCH_WARMUP=2000 DIGESTION_BENCH_ACCEPT=0.9 (attempt 2), 4000 / 0.95 (attempt 3).
final class AnalysisBenchmarkTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIGESTION_HEAVY_TESTS"] == "1", "heavy test")
    }

    static func referenceInput(seed: UInt64 = 1) -> AnalysisInput {
        // Frequencies from 0.03 to 0.5 per meal: rare foods to daily staples.
        let features = (0..<40).map { i in (id: String(format: "food%02d", i), probability: 0.03 + 0.47 * Double(i) / 39) }
        let scenario = SyntheticScenario(
            days: 180,
            features: features,
            kinds: ["abdominalPain", "bloating", "diarrhoea", "gas", "nausea", "heartburn"],
            baselinePerDay: [0.3, 0.25, 0.15, 0.1, 0.1, 0.1],
            trigger: .init(feature: "food10", kind: "diarrhoea", lagRange: 4..<8, multiplier: 4),
            seed: seed
        )
        let environment = ProcessInfo.processInfo.environment
        let warmup = environment["DIGESTION_BENCH_WARMUP"].flatMap(Int.init) ?? 1000
        let acceptance = environment["DIGESTION_BENCH_ACCEPT"].flatMap(Double.init) ?? 0.8
        return scenario.makeInput(config: AnalysisConfig(warmup: warmup, targetAcceptance: acceptance, seed: 11))
    }

    func testReferenceWorkload() async throws {
        let input = Self.referenceInput()
        let start = Date()
        let result = try await DigestionAnalysis.run(input)
        let total = Date().timeIntervalSince(start)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "BENCH reference run %.1f s, status %@, maxRhat %.4f, minBulkESS %.0f, divergences %d, peak RSS %.0f MB",
                     total, result.status.rawValue, result.diagnostics.maxRhat, result.diagnostics.minBulkESS,
                     result.diagnostics.divergences, Double(usage.ru_maxrss) / 1_048_576))
        for fit in result.diagnostics.fitDiagnostics {
            print(String(format: "BENCH fit %@: %.1f s, hours %d, symptoms %d, parameters %d, leapfrogs %d, treeDepthHits %d, maxRhat %.4f, minBulkESS %.0f, divergences %d, steps %@",
                         fit.name, fit.durationSeconds, fit.observedHours, fit.symptoms, fit.parameters, fit.leapfrogSteps,
                         fit.treeDepthHits, fit.maxRhat, fit.minBulkESS, fit.divergences,
                         fit.stepSizes.map { String(format: "%.3f", $0) }.joined(separator: ",")))
        }
        let trigger = result.features.first { $0.featureID == "food10" }!
        print("BENCH trigger food10 level \(trigger.level) probRaises \(trigger.overall!.probRaises) probPeakAbove \(trigger.overall!.probPeakAbove) lag \(String(describing: trigger.overall!.medianLagHours?.median)) main \(trigger.mainKind ?? "-")")
        let levels = Dictionary(grouping: result.features, by: \.level).mapValues(\.count)
        print("BENCH levels \(levels)")
        XCTAssertEqual(result.features.filter { $0.overall != nil }.count, 40)
    }
}
