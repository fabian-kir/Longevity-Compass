import XCTest
@testable import DigestionInsightsEngine

/// End-to-end behaviour of `DigestionAnalysis.run`: planted-trigger recovery
/// (B12), determinism, cancellation, edge paths and JSON round trips.
final class AnalysisTests: XCTestCase {

    /// Feature "trigger" multiplies kind "pain" by 4 between 4 and 8 h after
    /// exposure; "bystander" is eaten as often and does nothing. 180 days:
    /// with 90 days the integrated B9 `probRaises` is often near 0.5 even
    /// when the lag curve shows the peak clearly (see unit 3 note).
    static let plantedScenario = SyntheticScenario(
        days: 180,
        features: [("trigger", 0.3), ("bystander", 0.3)],
        kinds: ["pain", "bloating"],
        baselinePerDay: [0.5, 0.5],
        trigger: .init(feature: "trigger", kind: "pain", lagRange: 4..<8, multiplier: 4),
        seed: 42
    )

    /// Deterministic regression case. Recovery is not certain at this size:
    /// the same settings with scenario seed 43 give probRaises ≈ 0.66. Power
    /// by scenario is unit 4's simulation study.
    func testPlantedTriggerIsFound() async throws {
        let input = Self.plantedScenario.makeInput(config: fastConfig(seed: 7))
        let result = try await DigestionAnalysis.run(input)
        let trigger = try XCTUnwrap(result.features.first { $0.featureID == "trigger" })
        let bystander = try XCTUnwrap(result.features.first { $0.featureID == "bystander" })
        let summary = try XCTUnwrap(trigger.overall)

        XCTAssertGreaterThanOrEqual(summary.probRaises, 0.9)
        let lag = try XCTUnwrap(summary.medianLagHours)
        XCTAssertTrue((4.0...8.0).contains(lag.median), "median lag \(lag.median)")
        XCTAssertEqual(trigger.mainKind, "pain")
        XCTAssertGreaterThan(summary.peakRR.lower, 1.25)
        XCTAssertGreaterThan(summary.probPeakAbove, 0.9)
        XCTAssertGreaterThan(trigger.perKind["pain"]!.peakRR.median, trigger.perKind["bloating"]!.peakRR.median)
        // The peak of the chart curve sits inside the planted window.
        let peakHour = trigger.lagCurve.max { $0.rr.median < $1.rr.median }!.hour
        XCTAssertTrue((2...10).contains(peakHour), "curve peak at \(peakHour) h")

        let quiet = try XCTUnwrap(bystander.overall)
        XCTAssertLessThan(quiet.probRaises, 0.9)
        XCTAssertLessThan(quiet.probPeakAbove, 0.5)
        XCTAssertFalse([.earlySignal, .clearPattern].contains(bystander.level))

        // Run structure: three fits, sane diagnostics, chart data.
        XCTAssertEqual(result.diagnostics.fits, 3)
        XCTAssertEqual(result.diagnostics.fitDiagnostics.map(\.name), ["full", "firstHalf", "secondHalf"])
        XCTAssertLessThan(result.diagnostics.maxRhat, 1.05)
        XCTAssertNotNil(trigger.firstHalfProbRaises)
        XCTAssertEqual(trigger.lagCurve.count, 96)
        XCTAssertEqual(trigger.lagCurve.map(\.observedPairs).reduce(0, +), input.observedPairCount(feature: "trigger"))
        XCTAssertTrue(trigger.lagCurve.allSatisfy { $0.expectedPairsNull > 0 })
        XCTAssertEqual(result.inputFingerprint, DigestionAnalysis.fingerprint(input))
    }

    private static let smallScenario = SyntheticScenario(
        days: 30,
        features: [("a", 0.4), ("b", 0.3), ("rare", 0.01)],
        kinds: ["pain", "gas"],
        baselinePerDay: [0.6, 0.4],
        trigger: nil,
        seed: 9
    )

    private func stripDurations(_ result: AnalysisResult) -> AnalysisResult {
        var copy = result
        copy.diagnostics.durationSeconds = 0
        copy.diagnostics.fitDiagnostics = copy.diagnostics.fitDiagnostics.map { var fit = $0; fit.durationSeconds = 0; return fit }
        return copy
    }

    func testSameInputGivesIdenticalResult() async throws {
        let input = Self.smallScenario.makeInput(config: fastConfig(seed: 3, warmup: 150, samples: 150))
        let first = try await DigestionAnalysis.run(input)
        let second = try await DigestionAnalysis.run(input)
        // Everything except wall-clock durations is bitwise identical.
        XCTAssertEqual(stripDurations(first), stripDurations(second))
        XCTAssertEqual(first.features.map(\.featureID), ["a", "b", "rare"])
        let rare = first.features[2]
        XCTAssertEqual(rare.level, .notEnoughData)
        XCTAssertNil(rare.overall)
        XCTAssertEqual(rare.lagCurve, [])
    }

    func testResultAndInputSurviveJSON() async throws {
        let input = Self.smallScenario.makeInput(config: fastConfig(seed: 3, warmup: 100, samples: 100))
        let result = try await DigestionAnalysis.run(input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decodedInput = try JSONDecoder().decode(AnalysisInput.self, from: encoder.encode(input))
        XCTAssertEqual(decodedInput, input)
        let decodedResult = try JSONDecoder().decode(AnalysisResult.self, from: encoder.encode(result))
        XCTAssertEqual(decodedResult, result)
    }

    func testNoSymptomsGivesInsufficientData() async throws {
        var input = Self.smallScenario.makeInput(config: fastConfig())
        input.symptoms = []
        let result = try await DigestionAnalysis.run(input)
        XCTAssertEqual(result.status, .insufficientData)
        XCTAssertEqual(result.diagnostics.fits, 0)
        XCTAssertTrue(result.features.allSatisfy { $0.level == .notEnoughData && $0.overall == nil })
        XCTAssertEqual(result.features.count, 3)
        // NaN diagnostics encode as null and come back as NaN.
        let data = try JSONEncoder().encode(result)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"maxRhat\":null"))
        XCTAssertEqual(try JSONDecoder().decode(AnalysisResult.self, from: data), result)
    }

    func testNoEligibleFeatureGivesInsufficientData() async throws {
        var input = Self.smallScenario.makeInput(config: fastConfig())
        input.exposures = Array(input.exposures.filter { $0.featureID == "a" }.prefix(4))
        let result = try await DigestionAnalysis.run(input)
        XCTAssertEqual(result.status, .insufficientData)
        XCTAssertEqual(result.features.map(\.featureID), ["a"])
        XCTAssertEqual(result.features[0].exposureCount, 4)
        XCTAssertEqual(result.features[0].level, .notEnoughData)
    }

    func testCancellationThrowsCancellationError() async throws {
        let input = Self.plantedScenario.makeInput(config: AnalysisConfig(warmup: 100_000, samples: 100_000, seed: 1))
        let task = Task { try await DigestionAnalysis.run(input) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testProgressIsMonotoneAndEndsAtOne() async throws {
        let recorder = ProgressRecorder()
        let input = Self.smallScenario.makeInput(config: fastConfig(seed: 3, warmup: 100, samples: 100))
        _ = try await DigestionAnalysis.run(input) { recorder.record($0) }
        let values = recorder.values
        XCTAssertGreaterThan(values.count, 10)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
    }

    func testFingerprintIgnoresSeedButNotData() {
        let input = Self.smallScenario.makeInput(config: fastConfig(seed: 1))
        var reseeded = input
        reseeded.config.seed = 999
        XCTAssertEqual(DigestionAnalysis.fingerprint(input), DigestionAnalysis.fingerprint(reseeded))
        var changed = input
        changed.symptoms.removeLast()
        XCTAssertNotEqual(DigestionAnalysis.fingerprint(input), DigestionAnalysis.fingerprint(changed))
        // FNV-1a 64 reference values.
        XCTAssertEqual(DigestionAnalysis.fnv1a64(Data()), 0xCBF2_9CE4_8422_2325)
        XCTAssertEqual(DigestionAnalysis.fnv1a64(Data("a".utf8)), 0xAF63_DC4C_8601_EC8C)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

extension AnalysisInput {
    /// Brute-force pair count (observed symptoms, any kind, 0 ≤ lag < 96 h).
    func observedPairCount(feature: String) -> Int {
        let hours = Set(LagData(input: self).hours)
        let times = exposures.filter { $0.featureID == feature }.map(\.time)
        var count = 0
        for symptom in symptoms where symptomKinds.contains(symptom.kind) {
            guard hours.contains(absoluteHour(symptom.onset.timeIntervalSince1970)) else { continue }
            for time in times {
                let lag = symptom.onset.timeIntervalSince(time)
                if lag >= 0, lag < 96 * 3600 { count += 1 }
            }
        }
        return count
    }
}
