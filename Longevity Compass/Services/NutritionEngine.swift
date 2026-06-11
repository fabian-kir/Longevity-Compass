import Foundation

struct NutritionBucketRollup: Identifiable {
    let id = UUID()
    let bucket: NutrientBucket
    let status: BucketStatus
    let weeklyValue: Double?          // count: plants, days, or meals
    let target: Double
    let percentOfTarget: Double?
    let daysWithData: Int
    let lookbackDays: Int
    let summary: String
}

struct NutritionDigest {
    let rollups: [NutritionBucketRollup]
    let coverageDays: Int
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
        let fingerprinted = recent.compactMap { entry -> (entry: NutritionEntry, fingerprint: MealFingerprint)? in
            guard let f = entry.fingerprint else { return nil }
            return (entry, f)
        }

        let coverageDays = Set(recent.map { cal.startOfDay(for: $0.date) }).count

        let rollups: [NutritionBucketRollup] = NutrientBucket.allCases.map {
            rollup(for: $0, fingerprinted: fingerprinted, coverageDays: coverageDays, lookbackDays: lookback)
        }

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
        fingerprinted: [(entry: NutritionEntry, fingerprint: MealFingerprint)],
        coverageDays: Int,
        lookbackDays: Int
    ) -> NutritionBucketRollup {
        let value = weeklyValue(for: bucket, fingerprinted: fingerprinted)
        let target = bucket.weeklyTarget
        let percent = target > 0 ? value / target : nil
        let status = bucketStatus(percent: percent, daysWithData: coverageDays, lowerIsBetter: bucket.lowerIsBetter)

        return NutritionBucketRollup(
            bucket: bucket,
            status: status,
            weeklyValue: value,
            target: target,
            percentOfTarget: percent,
            daysWithData: coverageDays,
            lookbackDays: lookbackDays,
            summary: summary(bucket: bucket, status: status, value: value, target: target, coverageDays: coverageDays, lookbackDays: lookbackDays)
        )
    }

    private static func weeklyValue(
        for bucket: NutrientBucket,
        fingerprinted: [(entry: NutritionEntry, fingerprint: MealFingerprint)]
    ) -> Double {
        let cal = Calendar.current
        switch bucket {
        case .plantVariety:
            let unique = Set(fingerprinted.flatMap { $0.fingerprint.plantIngredients.map { $0.lowercased() } })
            return Double(unique.count)
        case .leafyGreenDays:
            return Double(daysWithCategory(.leafyGreens, fingerprinted: fingerprinted, cal: cal))
        case .omega3Days:
            return Double(daysWithCategory(.omega3Source, fingerprinted: fingerprinted, cal: cal))
        case .fermentedDays:
            return Double(daysWithCategory(.fermented, fingerprinted: fingerprinted, cal: cal))
        case .legumeDays:
            return Double(daysWithCategory(.legumes, fingerprinted: fingerprinted, cal: cal))
        case .ultraProcessedMeals:
            return Double(fingerprinted.filter { $0.fingerprint.contains(.ultraProcessed) }.count)
        case .processedMeatMeals:
            return Double(fingerprinted.filter { $0.fingerprint.contains(.processedMeat) }.count)
        case .friedMeals:
            return Double(fingerprinted.filter { $0.fingerprint.contains(.fried) }.count)
        }
    }

    private static func daysWithCategory(
        _ category: MealCategory,
        fingerprinted: [(entry: NutritionEntry, fingerprint: MealFingerprint)],
        cal: Calendar
    ) -> Int {
        let days = fingerprinted
            .filter { $0.fingerprint.contains(category) }
            .map { cal.startOfDay(for: $0.entry.date) }
        return Set(days).count
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

    private static func summary(
        bucket: NutrientBucket,
        status: BucketStatus,
        value: Double,
        target: Double,
        coverageDays: Int,
        lookbackDays: Int
    ) -> String {
        if coverageDays < HealthThresholds.Nutrition.minDaysWithDataForRollup {
            return "Log a few more days before this becomes meaningful."
        }
        let valueStr: String = {
            switch bucket {
            case .plantVariety:        return "\(Int(value)) plants"
            case .leafyGreenDays, .omega3Days, .fermentedDays, .legumeDays:
                return "\(Int(value))d/wk"
            case .ultraProcessedMeals, .processedMeatMeals, .friedMeals:
                return "\(Int(value)) meals"
            }
        }()
        let targetStr: String = {
            if bucket.lowerIsBetter { return "≤ \(Int(target))" }
            return "≥ \(Int(target))"
        }()
        let stem: String = {
            switch status {
            case .veryLow:  return "well below target"
            case .low:      return "below target"
            case .ok:       return "on target"
            case .high:     return "above limit"
            case .veryHigh: return "well above limit"
            case .unknown:  return "uncertain"
            }
        }()
        return "\(valueStr) over last \(lookbackDays)d — \(stem) (target \(targetStr))."
    }
}
