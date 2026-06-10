import SwiftUI
import SwiftData
import Charts

struct TrendsView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \ManualEntry.date, order: .reverse) private var entries: [ManualEntry]

    @State private var steps: [(date: Date, value: Double)] = []
    @State private var sleep: [(date: Date, value: Double)] = []
    @State private var rhr:   [(date: Date, value: Double)] = []
    @State private var weight: [(date: Date, value: Double)] = []
    @State private var vo2Max: [(date: Date, value: Double)] = []
    @State private var bp: [BloodPressureReading] = []
    @State private var isLoading = false

    var body: some View {
        List {
            cardioSection
            sleepSection
            heartSection
            bloodPressureSection
            bodyMassSection
            vo2Section
            habitsSection
        }
        .navigationTitle("Trends")
        .overlay {
            if isLoading && steps.isEmpty && bp.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: services.healthSnapshot.sampledAt) {
            await loadSeries()
        }
        .refreshable {
            await services.refresh()
            await loadSeries()
        }
    }

    // MARK: - Sections

    private var cardioSection: some View {
        Section("Activity") {
            let stepStats = TrendAnalyzer.stats(steps, lowerIsBetter: false)
            MetricRow(
                label: "Steps / day",
                stats: stepStats,
                format: { v in v.map { "\(Int($0.rounded()))" } ?? "—" }
            )
            MiniChart(series: steps, color: .blue, yLabel: "Steps")
            HStack {
                Stat(label: "Exercise (7d)", value: services.healthSnapshot.exerciseMinutesPerWeek.map { "\(Int($0.rounded())) min" })
                Stat(label: "Prior 7d", value: services.healthSnapshot.exerciseMinutesPriorWeek.map { "\(Int($0.rounded())) min" })
                Stat(label: "Workouts (7d)", value: services.healthSnapshot.workoutsLast7Days.map(String.init))
            }
        }
    }

    private var sleepSection: some View {
        Section("Sleep") {
            let stats = TrendAnalyzer.stats(sleep, lowerIsBetter: false)
            MetricRow(
                label: "Sleep / night",
                stats: stats,
                format: { v in v.map { String(format: "%.1f h", $0) } ?? "—" }
            )
            MiniBarChart(series: sleep, color: .indigo, yLabel: "Hours")
        }
    }

    private var heartSection: some View {
        Section("Heart") {
            let stats = TrendAnalyzer.stats(rhr, lowerIsBetter: true)
            MetricRow(
                label: "Resting HR",
                stats: stats,
                format: { v in v.map { "\(Int($0.rounded())) bpm" } ?? "—" }
            )
            MiniChart(series: rhr, color: .pink, yLabel: "bpm")
            HStack {
                Stat(label: "HRV (28d avg)", value: services.healthSnapshot.hrvAverage28d.map { "\(Int($0.rounded())) ms" })
                Stat(label: "RHR (90d)", value: services.healthSnapshot.restingHeartRateAverage90d.map { "\(Int($0.rounded())) bpm" })
            }
        }
    }

    private var bloodPressureSection: some View {
        Section("Blood pressure") {
            if bp.isEmpty {
                Text("No blood-pressure readings in Apple Health yet.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                Chart {
                    ForEach(bp, id: \.id) { r in
                        LineMark(x: .value("Date", r.date), y: .value("Systolic", r.systolic), series: .value("S", "Sys"))
                            .foregroundStyle(.red)
                        PointMark(x: .value("Date", r.date), y: .value("Systolic", r.systolic))
                            .foregroundStyle(.red)
                        LineMark(x: .value("Date", r.date), y: .value("Diastolic", r.diastolic), series: .value("S", "Dia"))
                            .foregroundStyle(.blue)
                        PointMark(x: .value("Date", r.date), y: .value("Diastolic", r.diastolic))
                            .foregroundStyle(.blue)
                    }
                    RuleMark(y: .value("Sys threshold", HealthThresholds.BP.badSystolicMin))
                        .foregroundStyle(.red.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    RuleMark(y: .value("Dia threshold", HealthThresholds.BP.badDiastolicMin))
                        .foregroundStyle(.blue.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                }
                .frame(height: 200)
                .chartYScale(domain: 50...190)
                .padding(.vertical, 4)

                let sysSeries = bp.map { (date: $0.date, value: $0.systolic) }
                let diaSeries = bp.map { (date: $0.date, value: $0.diastolic) }
                let sysStats = TrendAnalyzer.stats(sysSeries, lowerIsBetter: true)
                let diaStats = TrendAnalyzer.stats(diaSeries, lowerIsBetter: true)
                HStack {
                    Stat(label: "Sys (28d avg)", value: sysStats.mean28d.map { "\(Int($0.rounded())) mmHg" })
                    Stat(label: "Dia (28d avg)", value: diaStats.mean28d.map { "\(Int($0.rounded())) mmHg" })
                    Stat(label: "Readings", value: "\(bp.count)")
                }
            }
        }
    }

    private var bodyMassSection: some View {
        Section("Body weight") {
            let stats = TrendAnalyzer.stats(weight, lowerIsBetter: false)
            MetricRow(
                label: "Body weight",
                stats: stats,
                format: { v in v.map { String(format: "%.1f kg", $0) } ?? "—" }
            )
            MiniChart(series: weight, color: .green, yLabel: "kg")
            if let pct = stats.percentChange28v90, !pct.isNaN {
                Text(String(format: "%+.1f%% change over the last 90 days.", pct * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var vo2Section: some View {
        Section("VO₂ max") {
            if vo2Max.isEmpty {
                Text("Cardio fitness comes from your Apple Watch over time.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                let stats = TrendAnalyzer.stats(vo2Max, lowerIsBetter: false)
                MetricRow(
                    label: "VO₂ max",
                    stats: stats,
                    format: { v in v.map { String(format: "%.1f", $0) } ?? "—" }
                )
                MiniChart(series: vo2Max, color: .orange, yLabel: "ml/kg/min")
            }
        }
    }

    private var habitsSection: some View {
        Section("Habit completion (last 8 weeks)") {
            HabitWeeklyChart(entries: entries)
        }
    }

    // MARK: - Loading

    private func loadSeries() async {
        isLoading = true
        defer { isLoading = false }

        async let s  = try? services.healthKit.dailyStepsSeries(days: 30)
        async let sl = try? services.healthKit.sleepNightlySeries(days: 30)
        async let r  = try? services.healthKit.restingHeartRateSeries(days: 90)
        async let w  = try? services.healthKit.bodyMassSeries(days: 180)
        async let v  = try? services.healthKit.vo2MaxSeries(days: 365)
        async let b  = try? services.healthKit.bloodPressureSeries(days: 180)

        steps  = (await s)  ?? []
        sleep  = (await sl) ?? []
        rhr    = (await r)  ?? []
        weight = (await w)  ?? []
        vo2Max = (await v)  ?? []
        bp     = (await b)  ?? []
    }
}

// MARK: - Reusable rows

private struct MetricRow: View {
    let label: String
    let stats: TrendAnalyzer.SeriesStats
    let format: (Double?) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(format(stats.latestValue))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 14) {
                miniStat("7d",  value: format(stats.mean7d))
                miniStat("28d", value: format(stats.mean28d))
                miniStat("90d", value: format(stats.mean90d))
                Spacer()
                trendBadge(stats.trend28v90)
            }
        }
        .padding(.vertical, 4)
    }

    private func miniStat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).monospacedDigit()
        }
    }

    @ViewBuilder
    private func trendBadge(_ trend: TrendDirection) -> some View {
        HStack(spacing: 2) {
            Image(systemName: trend.arrowSymbol)
            Text(trend.displayLabel)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(trendColor(trend))
    }

    private func trendColor(_ trend: TrendDirection) -> Color {
        switch trend {
        case .improving: .green
        case .worsening: .red
        case .stable:    .secondary
        case .unknown:   .secondary
        }
    }
}

private struct MiniChart: View {
    let series: [(date: Date, value: Double)]
    let color: Color
    let yLabel: String

    var body: some View {
        if series.isEmpty {
            Text("No data").font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(series, id: \.date) { p in
                    LineMark(x: .value("Date", p.date), y: .value(yLabel, p.value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", p.date), y: .value(yLabel, p.value))
                        .foregroundStyle(color.opacity(0.5))
                        .symbolSize(8)
                }
            }
            .frame(height: 120)
        }
    }
}

private struct MiniBarChart: View {
    let series: [(date: Date, value: Double)]
    let color: Color
    let yLabel: String

    var body: some View {
        if series.isEmpty {
            Text("No data").font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(series, id: \.date) { p in
                    BarMark(x: .value("Date", p.date, unit: .day), y: .value(yLabel, p.value))
                        .foregroundStyle(color)
                }
            }
            .frame(height: 120)
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "—").font(.subheadline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Habit weekly chart

private struct HabitWeeklyChart: View {
    let entries: [ManualEntry]

    private let habitTypes: [(type: ManualEntryType, label: String)] = [
        (.proteinHabit, "Protein"),
        (.fiberHabit, "Fibre"),
        (.omega3Habit, "Omega-3"),
        (.dentalFloss, "Floss"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(habitTypes, id: \.label) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.label).font(.caption.weight(.semibold))
                    Chart {
                        ForEach(weeklyBuckets(for: row.type), id: \.weekStart) { bucket in
                            BarMark(
                                x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                                y: .value("Yes-days", bucket.yesDays)
                            )
                            .foregroundStyle(.green)
                        }
                    }
                    .frame(height: 60)
                    .chartYScale(domain: 0...7)
                    .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 1)) { _ in
                        AxisGridLine()
                    } }
                }
            }
        }
    }

    private func weeklyBuckets(for type: ManualEntryType) -> [(weekStart: Date, yesDays: Int)] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(weekStart: Date, yesDays: Int)] = []
        for weeksAgo in (0..<8).reversed() {
            guard
                let weekEnd = cal.date(byAdding: .day, value: -7 * weeksAgo, to: now),
                let weekStart = cal.date(byAdding: .day, value: -7, to: weekEnd)
            else { continue }
            let count = TrendAnalyzer.distinctDaysWithYes(entries, type: type, since: weekStart, until: weekEnd)
            buckets.append((weekStart, count))
        }
        return buckets
    }
}
