import Foundation

struct NutritionBucketRollup: Identifiable {
    let id = UUID()
    let bucket: NutrientBucket
    let status: BucketStatus
    let dailyAverage: Double?
    let target: Double?
    let percentOfTarget: Double?
    let daysWithData: Int
    let lookbackDays: Int
    let trend: TrendDirection
    let summary: String
}

struct NutritionDigest {
    let rollups: [NutritionBucketRollup]
    let coverageDays: Int          // distinct days with at least one entry in lookback
    let lookbackDays: Int
    let totalEntries: Int
    let costThisMonthUSD: Double
    let costAllTimeUSD: Double

    func rollup(for bucket: NutrientBucket) -> NutritionBucketRollup? {
        rollups.first { $0.bucket == bucket }
    }
}

enum NutritionEngine {

    static func digest(
        _ entries: [NutritionEntry],
        now: Date = .now,
        lookback: Int = HealthThresholds.Nutrition.rollupDays
    ) -> NutritionDigest {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -lookback, to: now) ?? now
        let recent = entries.filter { $0.date >= start && $0.date <= now }

        let coverageDays = Set(recent.map { cal.startOfDay(for: $0.date) }).count

        let rollups: [NutritionBucketRollup] = NutrientBucket.allCases.map {
            rollup(for: $0, entries: recent, lookbackDays: lookback, now: now)
        }

        // Cost
        let monthStart: Date = {
            var comps = cal.dateComponents([.year, .month], from: now)
            comps.day = 1
            return cal.date(from: comps) ?? now
        }()
        let monthCost = entries.filter { $0.date >= monthStart }.compactMap { $0.costUSD }.reduce(0, +)
        let totalCost = entries.compactMap { $0.costUSD }.reduce(0, +)

        return NutritionDigest(
            rollups: rollups,
            coverageDays: coverageDays,
            lookbackDays: lookback,
            totalEntries: recent.count,
            costThisMonthUSD: monthCost,
            costAllTimeUSD: totalCost
        )
    }

    // MARK: - Per-bucket rollup

    private static func rollup(
        for bucket: NutrientBucket,
        entries: [NutritionEntry],
        lookbackDays: Int,
        now: Date
    ) -> NutritionBucketRollup {
        let cal = Calendar.current
        let daysWithData = Set(entries.map { cal.startOfDay(for: $0.date) }).count
        let denomDays = Double(lookbackDays)

        switch bucket {
        case .protein:
            return summed(
                bucket: bucket,
                entries: entries,
                value: { $0.proteinGrams },
                target: HealthThresholds.Nutrition.proteinGramsTarget,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                denomDays: denomDays,
                now: now
            )
        case .fiber:
            return summed(
                bucket: bucket,
                entries: entries,
                value: { $0.fiberGrams },
                target: HealthThresholds.Nutrition.fiberGramsTarget,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                denomDays: denomDays,
                now: now
            )
        case .addedSugar:
            return summed(
                bucket: bucket,
                entries: entries,
                value: { $0.addedSugarGrams },
                target: HealthThresholds.Nutrition.addedSugarGramsLimit,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                denomDays: denomDays,
                now: now
            )
        case .saturatedFat:
            return summed(
                bucket: bucket,
                entries: entries,
                value: { $0.saturatedFatGrams },
                target: HealthThresholds.Nutrition.saturatedFatGramsLimit,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                denomDays: denomDays,
                now: now
            )
        case .sodium:
            return summed(
                bucket: bucket,
                entries: entries,
                value: { $0.sodiumMilligrams },
                target: HealthThresholds.Nutrition.sodiumMilligramsLimit,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                denomDays: denomDays,
                now: now
            )
        case .leafyGreens:
            return summed(
                bucket: bucket,
                entries: entries,
                value: { $0.leafyGreenServings },
                target: HealthThresholds.Nutrition.leafyGreensServingsTarget,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                denomDays: denomDays,
                now: now
            )
        case .fattyFish:
            // Weekly: count servings (entries flagged isFattyFish=true) in lookback, scale to weekly.
            let weeks = max(1.0, Double(lookbackDays) / 7.0)
            let total = entries.filter { $0.isFattyFish == true }.count
            let perWeek = Double(total) / weeks
            let target = HealthThresholds.Nutrition.fattyFishServingsPerWeekTarget
            let pct = target > 0 ? perWeek / target : nil
            let status = bucketStatus(percent: pct, daysWithData: daysWithData, lowerIsBetter: false)
            return NutritionBucketRollup(
                bucket: bucket,
                status: status,
                dailyAverage: perWeek,        // reused as "per-week" for display
                target: target,
                percentOfTarget: pct,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                trend: .unknown,
                summary: summary(bucket: bucket, status: status, average: perWeek, target: target, daysWithData: daysWithData, lookbackDays: lookbackDays)
            )
        case .ultraProcessed:
            // Average of per-entry score across entries (0..1 unitless). Lower is better.
            let scores = entries.compactMap { $0.ultraProcessedScore }
            let avg = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
            let target = HealthThresholds.Nutrition.ultraProcessedTargetMax
            let pct = avg.flatMap { target > 0 ? $0 / target : nil }
            let status = bucketStatus(percent: pct, daysWithData: daysWithData, lowerIsBetter: true)
            return NutritionBucketRollup(
                bucket: bucket,
                status: status,
                dailyAverage: avg,
                target: target,
                percentOfTarget: pct,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                trend: .unknown,
                summary: summary(bucket: bucket, status: status, average: avg, target: target, daysWithData: daysWithData, lookbackDays: lookbackDays)
            )
        case .eatingOccasions:
            let perDay = denomDays > 0 ? Double(entries.count) / denomDays : 0
            let limit  = HealthThresholds.Nutrition.eatingOccasionsPerDayMax
            let pct = limit > 0 ? perDay / limit : nil
            let status = bucketStatus(percent: pct, daysWithData: daysWithData, lowerIsBetter: true)
            return NutritionBucketRollup(
                bucket: bucket,
                status: status,
                dailyAverage: perDay,
                target: limit,
                percentOfTarget: pct,
                daysWithData: daysWithData,
                lookbackDays: lookbackDays,
                trend: .unknown,
                summary: summary(bucket: bucket, status: status, average: perDay, target: limit, daysWithData: daysWithData, lookbackDays: lookbackDays)
            )
        }
    }

    // Per-day summed buckets (gram-style nutrients) → average over lookback days.
    private static func summed(
        bucket: NutrientBucket,
        entries: [NutritionEntry],
        value: (NutritionEntry) -> Double?,
        target: Double,
        daysWithData: Int,
        lookbackDays: Int,
        denomDays: Double,
        now: Date
    ) -> NutritionBucketRollup {
        let sumAll = entries.compactMap(value).reduce(0, +)
        let dailyAvg = denomDays > 0 ? sumAll / denomDays : 0
        let percent = target > 0 ? dailyAvg / target : nil
        let status = bucketStatus(percent: percent, daysWithData: daysWithData, lowerIsBetter: bucket.lowerIsBetter)
        let trend = simpleTrend(bucket: bucket, entries: entries, value: value, now: now)
        return NutritionBucketRollup(
            bucket: bucket,
            status: status,
            dailyAverage: dailyAvg,
            target: target,
            percentOfTarget: percent,
            daysWithData: daysWithData,
            lookbackDays: lookbackDays,
            trend: trend,
            summary: summary(bucket: bucket, status: status, average: dailyAvg, target: target, daysWithData: daysWithData, lookbackDays: lookbackDays)
        )
    }

    private static func bucketStatus(percent: Double?, daysWithData: Int, lowerIsBetter: Bool) -> BucketStatus {
        guard daysWithData >= HealthThresholds.Nutrition.minDaysWithDataForRollup,
              let p = percent
        else { return .unknown }
        let t = HealthThresholds.Nutrition.self
        if lowerIsBetter {
            if p > t.veryHighFraction { return .veryHigh }
            if p > t.highFraction     { return .high }
            return .ok
        } else {
            if p < t.veryLowFraction  { return .veryLow }
            if p < t.lowFraction      { return .low }
            if p < t.okMinFraction    { return .low }
            return .ok
        }
    }

    private static func simpleTrend(
        bucket: NutrientBucket,
        entries: [NutritionEntry],
        value: (NutritionEntry) -> Double?,
        now: Date
    ) -> TrendDirection {
        let cal = Calendar.current
        let halfDays = HealthThresholds.Nutrition.rollupDays / 2
        guard let mid = cal.date(byAdding: .day, value: -halfDays, to: now) else { return .unknown }
        let recent = entries.filter { $0.date >= mid }.compactMap(value)
        let prior  = entries.filter { $0.date <  mid }.compactMap(value)
        guard recent.count >= 2, prior.count >= 2 else { return .unknown }
        let r = recent.reduce(0, +) / Double(max(1, halfDays))
        let p = prior.reduce(0, +)  / Double(max(1, halfDays))
        return TrendAnalyzer.direction(recent: r, prior: p, lowerIsBetter: bucket.lowerIsBetter)
    }

    private static func summary(
        bucket: NutrientBucket,
        status: BucketStatus,
        average: Double?,
        target: Double?,
        daysWithData: Int,
        lookbackDays: Int
    ) -> String {
        if daysWithData < HealthThresholds.Nutrition.minDaysWithDataForRollup {
            return "Need a few more days of nutrition entries before this is meaningful."
        }
        let avgStr: String = {
            guard let v = average else { return "—" }
            if bucket == .ultraProcessed { return String(format: "%.2f / 1.0", v) }
            if bucket == .sodium         { return String(format: "%.0f mg/day", v) }
            if bucket == .fattyFish      { return String(format: "%.1f/wk", v) }
            if bucket == .leafyGreens    { return String(format: "%.1f svg/day", v) }
            if bucket == .eatingOccasions { return String(format: "%.1f/day", v) }
            return String(format: "%.0f g/day", v)
        }()
        let targetStr: String = {
            guard let t = target else { return "—" }
            if bucket == .ultraProcessed { return String(format: "≤ %.2f", t) }
            if bucket == .sodium         { return String(format: "≤ %.0f mg", t) }
            if bucket == .fattyFish      { return String(format: "≥ %.0f/wk", t) }
            if bucket == .leafyGreens    { return String(format: "≥ %.0f/day", t) }
            if bucket == .eatingOccasions { return String(format: "≤ %.0f/day", t) }
            return bucket.lowerIsBetter ? String(format: "≤ %.0f g", t) : String(format: "≥ %.0f g", t)
        }()
        let stem: String = {
            switch (bucket, status) {
            case (_, .veryLow):  return "well below target"
            case (_, .low):      return "below target"
            case (_, .ok):       return "on target"
            case (_, .high):     return "above target"
            case (_, .veryHigh): return "well above target"
            case (_, .unknown):  return "uncertain"
            }
        }()
        return "\(bucket.displayLabel): \(avgStr) over last \(lookbackDays) d — \(stem) (target \(targetStr))."
    }
}
