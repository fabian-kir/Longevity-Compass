import Foundation

enum TrendAnalyzer {

    static func mean<T: BinaryFloatingPoint>(_ values: [T]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    static func filter<S: Sequence>(_ sequence: S, since: Date, until: Date = .now) -> [S.Element]
    where S.Element == (date: Date, value: Double) {
        sequence.filter { $0.date >= since && $0.date <= until }
    }

    static func windowMean(
        _ points: [(date: Date, value: Double)],
        days: Int,
        endingAt reference: Date = .now
    ) -> Double? {
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: reference) else {
            return nil
        }
        let values = points.filter { $0.date >= start && $0.date <= reference }.map(\.value)
        return mean(values)
    }

    static func windowValues(
        _ points: [(date: Date, value: Double)],
        days: Int,
        endingAt reference: Date = .now
    ) -> [Double] {
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: reference) else {
            return []
        }
        return points.filter { $0.date >= start && $0.date <= reference }.map(\.value)
    }

    static func direction(
        recent: Double?,
        prior: Double?,
        lowerIsBetter: Bool,
        threshold: Double = HealthThresholds.Trend.meaningfulRelativeChange
    ) -> TrendDirection {
        guard let r = recent, let p = prior, p != 0 else { return .unknown }
        let change = (r - p) / abs(p)
        if abs(change) < threshold { return .stable }
        let rising = change > 0
        let better = lowerIsBetter ? !rising : rising
        return better ? .improving : .worsening
    }

    static func distinctDaysWithYes(
        _ entries: [ManualEntry],
        type: ManualEntryType,
        since: Date,
        until: Date = .now
    ) -> Int {
        let cal = Calendar.current
        let days = entries
            .filter { $0.entryType == type && $0.booleanValue == true && $0.date >= since && $0.date <= until }
            .map { cal.startOfDay(for: $0.date) }
        return Set(days).count
    }

    static func mostRecent(
        _ entries: [ManualEntry],
        type: ManualEntryType
    ) -> ManualEntry? {
        entries.filter { $0.entryType == type }.max(by: { $0.date < $1.date })
    }

    static func entries(
        _ entries: [ManualEntry],
        of type: ManualEntryType,
        since: Date,
        until: Date = .now
    ) -> [ManualEntry] {
        entries.filter { $0.entryType == type && $0.date >= since && $0.date <= until }
    }

    static func daysAgo(_ date: Date, from reference: Date = .now) -> Int {
        Calendar.current.dateComponents([.day], from: date, to: reference).day ?? 0
    }

    struct SeriesStats {
        let latestValue: Double?
        let latestDate: Date?
        let mean7d: Double?
        let mean28d: Double?
        let mean90d: Double?
        let trend7v28: TrendDirection
        let trend28v90: TrendDirection
        let percentChange28v90: Double?
        let sampleCount: Int
    }

    static func stats(
        _ series: [(date: Date, value: Double)],
        lowerIsBetter: Bool = false,
        now: Date = .now
    ) -> SeriesStats {
        let latest = series.max(by: { $0.date < $1.date })
        let m7  = windowMean(series, days: 7, endingAt: now)
        let m28 = windowMean(series, days: 28, endingAt: now)
        let m90 = windowMean(series, days: 90, endingAt: now)
        let pct: Double? = {
            guard let m28, let m90, m90 != 0 else { return nil }
            return (m28 - m90) / abs(m90)
        }()
        return SeriesStats(
            latestValue: latest?.value,
            latestDate: latest?.date,
            mean7d: m7,
            mean28d: m28,
            mean90d: m90,
            trend7v28: direction(recent: m7, prior: m28, lowerIsBetter: lowerIsBetter),
            trend28v90: direction(recent: m28, prior: m90, lowerIsBetter: lowerIsBetter),
            percentChange28v90: pct,
            sampleCount: series.count
        )
    }
}
