import DigestionInsightsEngine
import Foundation

/// Display rules for Digestion Insights results: section order, row text,
/// chart data and report data. Pure; views only lay these out.
enum DigestionPresentation {

    // MARK: - Wording (B2)

    static let disclaimer = "Pattern matching only, not a diagnosis. Results are statistics, not medical data. AI meal recognition makes mistakes. Effects that build up over more than 96 hours are not covered."
    static let doctorLine = "Worth discussing with your doctor."
    static let methodologyURL = URL(string: "https://github.com/fabian-kir/Longevity-Direction/blob/main/docs/digestion-insights-methodology.md")!

    // MARK: - Sections

    struct Section: Identifiable, Equatable {
        let level: PatternLevel
        let rows: [Row]
        var id: PatternLevel { level }
        var title: String { DigestionPresentation.sectionTitle(level) }
        /// "Not enough data" starts collapsed.
        var startsCollapsed: Bool { level == .notEnoughData }
    }

    struct Row: Identifiable, Equatable {
        let featureID: String
        let name: String
        let kindLabel: String
        let level: PatternLevel
        let badge: String
        /// "median about 6 h"; early signals and clear patterns only.
        let lagText: String?
        /// "83 %" chance the food raises symptoms; nil without a fit.
        let confidenceText: String?
        /// "Can't tell apart from: Cheese, Butter"; nil when not confounded.
        let confoundedText: String?
        var id: String { featureID }
    }

    static let sectionOrder: [PatternLevel] = [.clearPattern, .earlySignal, .noLinkFound, .inconclusive, .notEnoughData]

    static func sectionTitle(_ level: PatternLevel) -> String {
        switch level {
        case .clearPattern:  "Clear patterns"
        case .earlySignal:   "Early signals"
        case .noLinkFound:   "No link found"
        case .inconclusive:  "No clear pattern yet"
        case .notEnoughData: "Not enough data"
        }
    }

    static func badge(_ level: PatternLevel) -> String {
        switch level {
        case .clearPattern:  "Clear pattern"
        case .earlySignal:   "Early signal"
        case .noLinkFound:   "No link found"
        case .inconclusive:  "No clear pattern yet"
        case .notEnoughData: "Not enough data"
        }
    }

    /// Non-empty sections in fixed order; rows by confidence, then name.
    static func sections(for result: AnalysisResult, taxonomy: IngredientTaxonomy = .shared) -> [Section] {
        let rows = result.features.map { row(for: $0, taxonomy: taxonomy) }
        let confidence = Dictionary(uniqueKeysWithValues: result.features.map { ($0.featureID, $0.overall?.probRaises ?? -1) })
        return sectionOrder.compactMap { level in
            let members = rows.filter { $0.level == level }.sorted {
                let (a, b) = (confidence[$0.featureID] ?? -1, confidence[$1.featureID] ?? -1)
                return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return members.isEmpty ? nil : Section(level: level, rows: members)
        }
    }

    static func row(for feature: FeatureResult, taxonomy: IngredientTaxonomy = .shared) -> Row {
        Row(
            featureID: feature.featureID,
            name: ExposureBuilder.displayName(of: feature.featureID, taxonomy: taxonomy),
            kindLabel: ExposureBuilder.featureKindLabel(of: feature.featureID),
            level: feature.level,
            badge: badge(feature.level),
            lagText: lagText(for: feature),
            confidenceText: feature.overall.map { percent($0.probRaises) },
            confoundedText: confoundedText(feature.confoundedWith, taxonomy: taxonomy)
        )
    }

    static func lagText(for feature: FeatureResult) -> String? {
        guard feature.level == .earlySignal || feature.level == .clearPattern,
              let lag = feature.overall?.medianLagHours else { return nil }
        return "median about \(hours(lag.median))"
    }

    static func confoundedText(_ ids: [String], taxonomy: IngredientTaxonomy = .shared) -> String? {
        guard !ids.isEmpty else { return nil }
        return "Can't tell apart from: " + ids.map { ExposureBuilder.displayName(of: $0, taxonomy: taxonomy) }.joined(separator: ", ")
    }

    static func percent(_ probability: Double) -> String {
        "\(Int((probability * 100).rounded())) %"
    }

    /// Whole hours ("6 h"); hours read better than days inside a 0–96 h window.
    static func hours(_ value: Double) -> String {
        "\(Int(value.rounded())) h"
    }

    static func ratio(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1)))
    }

    static func symptomLabel(_ kindRaw: String) -> String {
        SymptomKind(rawValue: kindRaw)?.label ?? kindRaw
    }

    // MARK: - Last-run line

    static func lastRunLine(latest: DigestionAnalysisRun?, lastGood: DigestionAnalysisRun?) -> String? {
        guard let latest else { return nil }
        if latest.status == .running {
            return lastGood.map { "Analysis running — showing results from \(date($0))" } ?? "Analysis running…"
        }
        if latest.status.isShowable { return "Updated \(date(latest))" }
        if let lastGood { return "Last run did not finish — showing results from \(date(lastGood))" }
        return "Last run did not finish. Results appear after a run that passes all checks."
    }

    private static func date(_ run: DigestionAnalysisRun) -> String {
        (run.finishedAt ?? run.startedAt).formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Chart data

    enum LevelBand: Int, CaseIterable, Comparable {
        case lowest, middle, highest

        var label: String {
            switch self {
            case .lowest:  "Lower level"
            case .middle:  "Middle level"
            case .highest: "Highest level"
            }
        }

        static func < (a: LevelBand, b: LevelBand) -> Bool { a.rawValue < b.rawValue }

        static func of(rank: Int, isTop: Bool) -> LevelBand {
            isTop ? .highest : (rank == 0 ? .lowest : .middle)
        }
    }

    /// One exposure–symptom pair: the symptom came `hoursAfter` hours after a meal with the feature.
    struct Pair: Identifiable, Equatable {
        let id: Int
        let hoursAfter: Double
        let kind: String
        let band: LevelBand
        /// 1-based position in its hour's stack (dot plot).
        let stack: Int
    }

    /// Pairs from the stored input: every symptom within `maxLag` hours after
    /// an exposure of the feature. Same counting as the engine's `observedPairs`.
    static func pairs(featureID: String, input: AnalysisInput) -> [Pair] {
        let maxLag = Double(input.config.maxLagHours)
        let times = input.exposures.filter { $0.featureID == featureID && $0.value > 0 }.map(\.time).sorted()
        var raw: [(hours: Double, kind: String, band: LevelBand)] = []
        for symptom in input.symptoms {
            for time in times {
                let lag = symptom.onset.timeIntervalSince(time) / 3600
                if lag >= 0 && lag < maxLag {
                    raw.append((lag, symptom.kind, LevelBand.of(rank: symptom.levelRank, isTop: symptom.isTopLevel)))
                }
            }
        }
        raw.sort { ($0.hours, $0.kind) < ($1.hours, $1.kind) }
        var heights: [Int: Int] = [:]
        return raw.enumerated().map { index, item in
            let hour = Int(item.hours.rounded(.down))
            heights[hour, default: 0] += 1
            return Pair(id: index, hoursAfter: item.hours, kind: item.kind, band: item.band, stack: heights[hour]!)
        }
    }

    /// Expected pairs per lag hour if the food had no effect, smoothed with a
    /// centred 5-hour moving average for display only.
    static func smoothedExpected(_ curve: [LagPoint], radius: Int = 2) -> [(hour: Int, expected: Double)] {
        let values = curve.sorted { $0.hour < $1.hour }
        return values.indices.map { i in
            let window = values[max(0, i - radius)...min(values.count - 1, i + radius)]
            return (values[i].hour, window.map(\.expectedPairsNull).reduce(0, +) / Double(window.count))
        }
    }

    // MARK: - Report

    struct Report: Equatable {
        struct PeriodLine: Equatable { let start: Date; let end: Date? }
        struct CountLine: Equatable { let kind: String; let level: String; let count: Int }
        struct FeatureLine: Equatable {
            let name: String
            let kindLabel: String
            let level: String
            let peak: String
            let confidence: String
            let delay: String
            let exposures: Int
        }
        struct LogLine: Equatable { let onset: Date; let kind: String; let level: String }

        let generatedAt: Date
        let periods: [PeriodLine]
        let daysWithMeals: Int
        let symptomCounts: [CountLine]
        let features: [FeatureLine]
        let resultDate: Date?
        let log: [LogLine]
        let disclaimer: String
    }

    /// Feature table lists every analysed feature except "Not enough data", in section order.
    static func report(
        periods: [DigestionTrackingPeriod],
        symptoms: [SymptomEntry],
        currentInput: AnalysisInput?,
        result: AnalysisResult?,
        resultDate: Date?,
        now: Date,
        calendar: Calendar = .current,
        taxonomy: IngredientTaxonomy = .shared
    ) -> Report {
        var counts: [Report.CountLine] = []
        for kind in SymptomKind.allCases {
            for level in kind.levels {
                let n = symptoms.filter { $0.kind == kind && $0.level == level }.count
                if n > 0 { counts.append(Report.CountLine(kind: kind.label, level: level.label, count: n)) }
            }
        }

        var days = Set<Date>()
        for window in currentInput?.windows ?? [] {
            var day = calendar.startOfDay(for: window.start)
            while day < window.end {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        var featureLines: [Report.FeatureLine] = []
        if let result, result.status == .ok || result.status == .insufficientData {
            for section in sections(for: result, taxonomy: taxonomy) where section.level != .notEnoughData {
                for row in section.rows {
                    guard let feature = result.features.first(where: { $0.featureID == row.featureID }) else { continue }
                    let peak = feature.overall.map { "\(ratio($0.peakRR.median)) (\(ratio($0.peakRR.lower))–\(ratio($0.peakRR.upper)))" } ?? "—"
                    let delay = feature.overall?.medianLagHours.map { hours($0.median) } ?? "—"
                    featureLines.append(Report.FeatureLine(
                        name: row.name, kindLabel: row.kindLabel, level: row.badge, peak: peak,
                        confidence: row.confidenceText ?? "—", delay: delay, exposures: feature.exposureCount
                    ))
                }
            }
        }

        return Report(
            generatedAt: now,
            periods: periods.sorted { $0.start < $1.start }.map { Report.PeriodLine(start: $0.start, end: $0.end) },
            daysWithMeals: days.count,
            symptomCounts: counts,
            features: featureLines,
            resultDate: resultDate,
            log: symptoms.sorted { $0.onset < $1.onset }.map {
                Report.LogLine(onset: $0.onset, kind: $0.kind?.label ?? $0.kindRaw, level: $0.level?.label ?? $0.levelRaw)
            },
            disclaimer: disclaimer
        )
    }
}

/// `AnalysisInput` and `AnalysisResult` of the last good run, for reproduction (B15).
struct DigestionAnalysisExport: Codable {
    let exportedAt: Date
    let note: String
    let input: AnalysisInput
    let result: AnalysisResult
}
