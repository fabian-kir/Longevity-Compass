import DigestionInsightsEngine
import SwiftData
import XCTest
@testable import Longevity_Compass

@MainActor
final class DigestionPresentationTests: XCTestCase {
    /// Keeps the container alive; a context outlives its container only by crashing.
    private var container: ModelContainer?
    /// 2026-01-01 00:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_767_225_600)

    private func at(hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    private func summary(prob: Double, lag: Double? = 6, peak: Double = 2) -> EffectSummary {
        EffectSummary(
            peakRR: Interval(median: peak, lower: 1.1, upper: 4),
            averageRR: Interval(median: 1.1, lower: 0.9, upper: 1.4),
            excessPerExposure: Interval(median: 0.2, lower: 0.05, upper: 0.4),
            medianLagHours: lag.map { Interval(median: $0, lower: 3, upper: 12) },
            probRaises: prob,
            probPeakAbove: prob
        )
    }

    private func feature(_ id: String, _ level: PatternLevel, prob: Double? = nil, confounded: [String] = []) -> FeatureResult {
        FeatureResult(
            featureID: id, exposureCount: 20, symptomsAfterCount: 8, level: level,
            overall: prob.map { summary(prob: $0) }, perKind: [:], mainKind: "diarrhoea",
            firstHalfProbRaises: 0.9, secondHalfProbRaises: 0.85,
            lagCurve: (0..<96).map { LagPoint(hour: $0, rr: Interval(median: 1, lower: 0.8, upper: 1.2), observedPairs: 0, expectedPairsNull: Double($0 % 2)) },
            confoundedWith: confounded
        )
    }

    private func result(_ features: [FeatureResult], status: AnalysisStatus = .ok) -> AnalysisResult {
        AnalysisResult(
            status: status,
            diagnostics: RunDiagnostics(maxRhat: 1.004, minBulkESS: 600, divergences: 0, durationSeconds: 100, fits: 3),
            features: features,
            inputFingerprint: 1
        )
    }

    // MARK: - Sections and rows

    func testGroupingAndOrderByLevel() {
        let sections = DigestionPresentation.sections(for: result([
            feature("ingredient:en:tomato", .inconclusive, prob: 0.5),
            feature("allergen:en:milk", .clearPattern, prob: 0.95),
            feature("ingredient:en:rice", .notEnoughData),
            feature("ingredient:en:coffee", .earlySignal, prob: 0.82),
            feature("ingredient:en:onion", .noLinkFound, prob: 0.3),
            feature("allergen:en:gluten", .earlySignal, prob: 0.88),
        ]))
        XCTAssertEqual(sections.map(\.level), [.clearPattern, .earlySignal, .noLinkFound, .inconclusive, .notEnoughData])
        XCTAssertEqual(sections.map(\.title), ["Clear patterns", "Early signals", "No link found", "No clear pattern yet", "Not enough data"])
        XCTAssertEqual(sections[1].rows.map(\.name), ["Gluten", "Coffee"], "Higher confidence first")
        XCTAssertTrue(sections.last!.startsCollapsed)
        XCTAssertFalse(sections[0].startsCollapsed)
    }

    func testEmptySectionsOmitted() {
        let sections = DigestionPresentation.sections(for: result([feature("allergen:en:milk", .inconclusive, prob: 0.6)]))
        XCTAssertEqual(sections.map(\.level), [.inconclusive])
    }

    func testRowTextLagOnlyForEarlyAndClear() {
        let clear = DigestionPresentation.row(for: feature("allergen:en:milk", .clearPattern, prob: 0.951))
        XCTAssertEqual(clear.lagText, "median about 6 h")
        XCTAssertEqual(clear.confidenceText, "95 %")
        XCTAssertEqual(clear.badge, "Clear pattern")
        XCTAssertEqual(clear.kindLabel, "Allergen")
        XCTAssertEqual(DigestionPresentation.row(for: feature("allergen:en:milk", .earlySignal, prob: 0.8)).lagText, "median about 6 h")
        XCTAssertNil(DigestionPresentation.row(for: feature("allergen:en:milk", .inconclusive, prob: 0.6)).lagText)
        XCTAssertNil(DigestionPresentation.row(for: feature("allergen:en:milk", .noLinkFound, prob: 0.2)).lagText)
        let none = DigestionPresentation.row(for: feature("allergen:en:milk", .notEnoughData))
        XCTAssertNil(none.lagText)
        XCTAssertNil(none.confidenceText)
    }

    func testConfoundedText() {
        let row = DigestionPresentation.row(for: feature("ingredient:en:onion", .inconclusive, prob: 0.5, confounded: ["ingredient:en:garlic", "group:en:onion-family-vegetable"]))
        XCTAssertEqual(row.confoundedText, "Can't tell apart from: Garlic, Onion-family vegetable")
        XCTAssertNil(DigestionPresentation.row(for: feature("ingredient:en:onion", .inconclusive, prob: 0.5)).confoundedText)
    }

    func testLastRunLine() {
        let good = DigestionAnalysisRun(startedAt: t0, finishedAt: at(hours: 1), status: .ok)
        let failed = DigestionAnalysisRun(startedAt: at(hours: 24), finishedAt: at(hours: 25), status: .notConverged)
        XCTAssertNil(DigestionPresentation.lastRunLine(latest: nil, lastGood: nil))
        XCTAssertTrue(DigestionPresentation.lastRunLine(latest: good, lastGood: good)!.hasPrefix("Updated "))
        XCTAssertTrue(DigestionPresentation.lastRunLine(latest: failed, lastGood: good)!.hasPrefix("Last run did not finish — showing results from "))
        XCTAssertTrue(DigestionPresentation.lastRunLine(latest: failed, lastGood: nil)!.hasPrefix("Last run did not finish."))
    }

    // MARK: - Chart data

    func testPairComputation() {
        let feature = "allergen:en:milk"
        let input = AnalysisInput(
            exposures: [
                ExposureEvent(featureID: feature, time: at(hours: 0), value: 1),
                ExposureEvent(featureID: feature, time: at(hours: 24), value: 0.5),
                ExposureEvent(featureID: "ingredient:en:rice", time: at(hours: 1), value: 1),
            ],
            symptoms: [
                SymptomEvent(kind: "diarrhoea", onset: at(hours: 5), levelRank: 1, isTopLevel: true),
                SymptomEvent(kind: "bloating", onset: at(hours: 5.5), levelRank: 0, isTopLevel: false),
                SymptomEvent(kind: "abdominalPain", onset: at(hours: 26), levelRank: 1, isTopLevel: false),
                SymptomEvent(kind: "gas", onset: at(hours: 100), levelRank: 0, isTopLevel: true),
            ],
            windows: [ObservationWindow(start: at(hours: 0), end: at(hours: 120))],
            symptomKinds: ["abdominalPain", "bloating", "diarrhoea", "gas"],
            config: AnalysisConfig(seed: 0)
        )
        let pairs = DigestionPresentation.pairs(featureID: feature, input: input)
        XCTAssertEqual(pairs.map(\.hoursAfter), [2, 5, 5.5, 26, 76])
        XCTAssertEqual(pairs.map(\.kind), ["abdominalPain", "diarrhoea", "bloating", "abdominalPain", "gas"])
        XCTAssertEqual(pairs.map(\.stack), [1, 1, 2, 1, 1])
        XCTAssertEqual(pairs.map(\.band), [.middle, .highest, .lowest, .middle, .highest])
    }

    func testSmoothedExpectedIsMovingAverage() {
        let curve = (0..<6).map { LagPoint(hour: $0, rr: Interval(median: 1, lower: 1, upper: 1), observedPairs: 0, expectedPairsNull: $0 == 2 ? 5 : 0) }
        let smoothed = DigestionPresentation.smoothedExpected(curve)
        XCTAssertEqual(smoothed.map(\.hour), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(smoothed[0].expected, 5.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(smoothed[2].expected, 1.0, accuracy: 1e-12)
        XCTAssertEqual(smoothed[5].expected, 0, accuracy: 1e-12)
    }

    // MARK: - Report

    func testReportDataAssembly() {
        let periods = [DigestionTrackingPeriod(start: at(hours: 0), end: at(hours: 72))]
        let symptoms = [
            SymptomEntry(onset: at(hours: 30), kind: .diarrhoea, level: .watery),
            SymptomEntry(onset: at(hours: 10), kind: .diarrhoea, level: .loose),
            SymptomEntry(onset: at(hours: 12), kind: .diarrhoea, level: .loose),
            SymptomEntry(onset: at(hours: 50), kind: .gas, level: .present),
        ]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let input = AnalysisInput(
            exposures: [], symptoms: [],
            windows: [ObservationWindow(start: at(hours: 0), end: at(hours: 24)), ObservationWindow(start: at(hours: 48), end: at(hours: 60))],
            symptomKinds: [], config: AnalysisConfig(seed: 0)
        )
        let report = DigestionPresentation.report(
            periods: periods, symptoms: symptoms, currentInput: input,
            result: result([
                feature("allergen:en:milk", .clearPattern, prob: 0.97),
                feature("ingredient:en:rice", .notEnoughData),
                feature("ingredient:en:onion", .noLinkFound, prob: 0.2),
            ]),
            resultDate: at(hours: 70), now: at(hours: 72), calendar: utc
        )
        XCTAssertEqual(report.daysWithMeals, 2)
        XCTAssertEqual(report.periods, [.init(start: at(hours: 0), end: at(hours: 72))])
        XCTAssertEqual(report.symptomCounts, [
            .init(kind: "Diarrhoea", level: "Loose", count: 2),
            .init(kind: "Diarrhoea", level: "Watery", count: 1),
            .init(kind: "Gas", level: "More than usual", count: 1),
        ])
        XCTAssertEqual(report.features.map(\.name), ["Milk", "Onion"], "Not enough data left out, section order kept")
        XCTAssertEqual(report.features[0].level, "Clear pattern")
        XCTAssertEqual(report.features[0].confidence, "97 %")
        XCTAssertEqual(report.features[0].delay, "6 h")
        let r = DigestionPresentation.ratio
        XCTAssertEqual(report.features[0].peak, "\(r(2)) (\(r(1.1))–\(r(4)))")
        XCTAssertEqual(report.log.map(\.onset), [at(hours: 10), at(hours: 12), at(hours: 30), at(hours: 50)])
        XCTAssertEqual(report.disclaimer, DigestionPresentation.disclaimer)
    }

    func testReportOmitsUnconvergedResult() {
        let report = DigestionPresentation.report(
            periods: [], symptoms: [], currentInput: nil,
            result: result([feature("allergen:en:milk", .clearPattern, prob: 0.97)], status: .notConverged),
            resultDate: nil, now: t0
        )
        XCTAssertTrue(report.features.isEmpty)
    }

    func testDisclaimerFollowsProductRules() {
        let text = DigestionPresentation.disclaimer.lowercased()
        XCTAssertTrue(text.contains("ai meal recognition makes mistakes"))
        XCTAssertTrue(text.contains("statistics, not medical data"))
        XCTAssertTrue(text.contains("96 hours"))
        for banned in ["safe", "fodmap", "intoleran", "allergy test", "elimination"] {
            XCTAssertFalse(text.contains(banned), banned)
        }
    }

    // MARK: - Mock data

    func testMockDataContainsPeriodSymptomsAndProfiles() {
        let mock = MockData.digestionMock(recentMeals: [])
        let days = Calendar.current.dateComponents([.day], from: mock.period.start, to: .now).day ?? 0
        XCTAssertEqual(days, MockData.digestionTrackingDays, accuracy: 1)
        XCTAssertNil(mock.period.end)
        XCTAssertTrue(mock.meals.count > 300)
        XCTAssertTrue(mock.meals.allSatisfy { $0.ingredientProfile != nil })
        XCTAssertTrue(mock.meals.contains { $0.ingredientProfile?.allergens.contains { $0.source == .declared } == true })
        XCTAssertTrue(mock.meals.contains { $0.ingredientProfile?.allergens.contains { $0.source == .ai } == true })
        XCTAssertTrue(mock.meals.contains { $0.date < mock.period.start }, "96 h of exposure history before the period")

        let diarrhoea = mock.symptoms.filter { $0.kind == .diarrhoea }
        XCTAssertTrue(diarrhoea.count > 30)
        XCTAssertTrue(mock.symptoms.contains { $0.kind == .bloating })
        XCTAssertTrue(mock.symptoms.allSatisfy { $0.onset >= mock.period.start })

        // Planted: most diarrhoea 4–8 h after a milk meal.
        let milkTimes = mock.meals.filter {
            $0.ingredientProfile?.contains(.milk) == true && $0.ingredientProfile?.isFree(from: .lactoseFree) == false
        }.map(\.date)
        let planted = diarrhoea.filter { s in milkTimes.contains { (4 * 3600...8 * 3600).contains(s.onset.timeIntervalSince($0)) } }
        XCTAssertGreaterThan(Double(planted.count) / Double(diarrhoea.count), 0.7)

        // Deterministic.
        let again = MockData.digestionMock(recentMeals: [])
        XCTAssertEqual(again.symptoms.map(\.onset), mock.symptoms.map(\.onset))
    }

    // MARK: - Real run (manual)

    /// Real engine on the mock data, as "Run analysis now" does it. Heavy (minutes):
    /// run with `TEST_RUNNER_DIGESTION_HEAVY_TESTS=1 xcodebuild test …`.
    func testRealAnalysisOnMockData() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIGESTION_HEAVY_TESTS"] == "1", "Set DIGESTION_HEAVY_TESTS=1")
        let schema = Schema([NutritionEntry.self, SymptomEntry.self, DigestionTrackingPeriod.self, DigestionAnalysisRun.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        self.container = container
        let store = LocalDataStore(context: container.mainContext)
        let mock = MockData.digestionMock(recentMeals: [])
        container.mainContext.insert(mock.period)
        mock.meals.forEach { container.mainContext.insert($0) }
        mock.symptoms.forEach { container.mainContext.insert($0) }
        store.saveContext()

        let service = DigestionAnalysisService(store: store)
        let input = service.buildInput()
        let started = Date()
        let status = await service.run()
        let seconds = Date().timeIntervalSince(started)
        let result = try XCTUnwrap(service.latestRun?.resultJSON.flatMap { DigestionAnalysisService.decode(AnalysisResult.self, from: $0) })
        var lines = [
            "DIGESTION RUN: status \(status.map(\.rawValue) ?? "nil"), attempts \(service.latestRun?.attempts ?? 0), wall \(Int(seconds)) s",
            "input: \(input.exposures.count) exposures, \(Set(input.exposures.map(\.featureID)).count) features, \(input.symptoms.count) symptoms, \(input.windows.count) windows, kinds \(input.symptomKinds)",
            "diagnostics: maxRhat \(result.diagnostics.maxRhat), minBulkESS \(result.diagnostics.minBulkESS), divergences \(result.diagnostics.divergences), engine \(Int(result.diagnostics.durationSeconds)) s",
        ]
        for fit in result.diagnostics.fitDiagnostics {
            lines.append("fit \(fit.name): \(fit.parameters) params, \(Int(fit.durationSeconds)) s, rhat \(fit.maxRhat), ess \(fit.minBulkESS), div \(fit.divergences)")
        }
        for f in result.features.sorted(by: { ($0.overall?.probRaises ?? -1) > ($1.overall?.probRaises ?? -1) }).prefix(12) {
            lines.append("  \(f.featureID): \(f.level.rawValue) p=\(f.overall?.probRaises ?? .nan) lag=\(f.overall?.medianLagHours?.median ?? .nan) n=\(f.exposureCount)")
        }
        print(lines.joined(separator: "\n"))
        XCTAssertNotEqual(status, .failed)
    }
}
