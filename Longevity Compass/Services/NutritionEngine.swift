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

/// A deliberately coarse view of dietary breadth. These values come from meal-photo
/// categories, so they describe patterns rather than claiming micronutrient precision.
struct NutritionPatternSnapshot {
    let beneficialGroupsSeen: Int
    let beneficialGroupTarget: Int
    let mealsWithoutLimitFlags: Int
    let assessedMeals: Int

    var mealsWithoutLimitFlagsFraction: Double? {
        guard assessedMeals > 0 else { return nil }
        return Double(mealsWithoutLimitFlags) / Double(assessedMeals)
    }
}

struct NutritionGuidance {
    enum Tone {
        case add
        case rebalance
        case maintain
    }

    let tone: Tone
    let bucket: NutrientBucket?
    let eyebrow: String
    let title: String
    let rationale: String
    let ideas: [String]
    let systemImage: String
}

struct NutritionDigest {
    let rollups: [NutritionBucketRollup]
    let coverageDays: Int
    let lookbackDays: Int
    let totalEntries: Int
    let costThisMonthUSD: Double
    let costAllTimeUSD: Double
    var pattern: NutritionPatternSnapshot = NutritionPatternSnapshot(
        beneficialGroupsSeen: 0,
        beneficialGroupTarget: 9,
        mealsWithoutLimitFlags: 0,
        assessedMeals: 0
    )
    var estimatedCaloriesPerLoggedDay: Double?
    var energyEstimateDays: Int = 0

    func rollup(for bucket: NutrientBucket) -> NutritionBucketRollup? {
        rollups.first { $0.bucket == bucket }
    }

    /// One high-value action beats asking the user to interpret every weekly signal.
    /// Limit patterns take priority when they are above their guardrail; otherwise
    /// the largest beneficial-food gap becomes the next-meal suggestion.
    var priorityGuidance: NutritionGuidance? {
        guard totalEntries > 0 else { return nil }

        let limitConcern = rollups
            .filter { $0.bucket.lowerIsBetter && ($0.status == .high || $0.status == .veryHigh) }
            .max { lhs, rhs in
                (lhs.percentOfTarget ?? 0) < (rhs.percentOfTarget ?? 0)
            }
        if let limitConcern {
            return guidanceForLimit(limitConcern)
        }

        let beneficialGap = rollups
            .filter { !$0.bucket.lowerIsBetter }
            .min { lhs, rhs in
                (lhs.percentOfTarget ?? 0) < (rhs.percentOfTarget ?? 0)
            }
        if let beneficialGap, (beneficialGap.percentOfTarget ?? 0) < 1 {
            return guidanceForAddition(beneficialGap)
        }

        return NutritionGuidance(
            tone: .maintain,
            bucket: nil,
            eyebrow: "Pattern looking strong",
            title: "Keep the next meal varied",
            rationale: "Your logged food-pattern goals are currently covered.",
            ideas: ["Choose a plant you have not logged this week", "Keep the plate mostly minimally processed"],
            systemImage: "sparkles"
        )
    }

    private func guidanceForAddition(_ rollup: NutritionBucketRollup) -> NutritionGuidance {
        let value = Int((rollup.weeklyValue ?? 0).rounded())
        let target = Int(rollup.target.rounded())
        switch rollup.bucket {
        case .plantVariety:
            return NutritionGuidance(
                tone: .add,
                bucket: rollup.bucket,
                eyebrow: "Next best addition",
                title: "Add two plants you have not had",
                rationale: "\(value) of \(target) distinct plants are represented in your logged week.",
                ideas: ["Top oats or yoghurt with berries and seeds", "Add two different vegetables to dinner"],
                systemImage: "leaf.circle.fill"
            )
        case .leafyGreenDays:
            return NutritionGuidance(
                tone: .add,
                bucket: rollup.bucket,
                eyebrow: "Next best addition",
                title: "Put something dark green on the plate",
                rationale: "Leafy greens appear on \(value) of \(target) target days this week.",
                ideas: ["Add spinach or rocket as a side", "Stir kale or chard into a warm meal"],
                systemImage: "leaf.fill"
            )
        case .omega3Days:
            return NutritionGuidance(
                tone: .add,
                bucket: rollup.bucket,
                eyebrow: "Next best addition",
                title: "Choose an omega-3 source",
                rationale: "Omega-3-rich foods appear on \(value) of \(target) target days this week.",
                ideas: ["Choose salmon, sardines, mackerel or trout", "Use chia, flax or walnuts in a plant-based meal"],
                systemImage: "fish.fill"
            )
        case .fermentedDays:
            return NutritionGuidance(
                tone: .add,
                bucket: rollup.bucket,
                eyebrow: "Next best addition",
                title: "Add a fermented food",
                rationale: "Fermented foods appear on \(value) of \(target) target days this week.",
                ideas: ["Try live-culture yoghurt or kefir", "Add kimchi, sauerkraut or miso"],
                systemImage: "bubbles.and.sparkles.fill"
            )
        case .legumeDays:
            return NutritionGuidance(
                tone: .add,
                bucket: rollup.bucket,
                eyebrow: "Next best addition",
                title: "Build a meal around legumes",
                rationale: "Beans, lentils or peas appear on \(value) of \(target) target days this week.",
                ideas: ["Add lentils or chickpeas to a bowl", "Choose tofu, edamame or bean chilli"],
                systemImage: "circle.grid.2x2.fill"
            )
        case .ultraProcessedMeals, .processedMeatMeals, .friedMeals:
            return guidanceForLimit(rollup)
        }
    }

    private func guidanceForLimit(_ rollup: NutritionBucketRollup) -> NutritionGuidance {
        let value = Int((rollup.weeklyValue ?? 0).rounded())
        switch rollup.bucket {
        case .ultraProcessedMeals:
            return NutritionGuidance(
                tone: .rebalance,
                bucket: rollup.bucket,
                eyebrow: "Pattern to rebalance",
                title: "Make the next meal recognisably whole-food",
                rationale: "\(value) logged meals carried an ultra-processed flag this week.",
                ideas: ["Choose a short-ingredient-list staple", "Pair a convenient food with fruit, vegetables or legumes"],
                systemImage: "shippingbox.fill"
            )
        case .processedMeatMeals:
            return NutritionGuidance(
                tone: .rebalance,
                bucket: rollup.bucket,
                eyebrow: "Pattern to rebalance",
                title: "Swap the next processed-meat serving",
                rationale: "\(value) logged meals included processed meat this week.",
                ideas: ["Use beans, eggs, fish or unprocessed poultry", "Make vegetables the centre of the meal"],
                systemImage: "arrow.triangle.swap"
            )
        case .friedMeals:
            return NutritionGuidance(
                tone: .rebalance,
                bucket: rollup.bucket,
                eyebrow: "Pattern to rebalance",
                title: "Choose roasted, grilled or steamed next",
                rationale: "\(value) logged meals were fried this week.",
                ideas: ["Keep the same base food and change the preparation", "Add a fresh or cooked vegetable side"],
                systemImage: "flame.fill"
            )
        case .plantVariety, .leafyGreenDays, .omega3Days, .fermentedDays, .legumeDays:
            return guidanceForAddition(rollup)
        }
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
            rollup(
                for: $0,
                recent: recent,
                fingerprinted: fingerprinted,
                coverageDays: coverageDays,
                lookbackDays: lookback
            )
        }
        let pattern = patternSnapshot(from: fingerprinted, recent: recent)

        let energyByDay = Dictionary(grouping: recent.compactMap { entry -> (Date, Double)? in
            guard let kcal = entry.caloriesKcal, kcal > 0 else { return nil }
            return (cal.startOfDay(for: entry.date), kcal)
        }, by: \.0)
            .mapValues { $0.reduce(0) { $0 + $1.1 } }
        let energyAverage: Double? = energyByDay.isEmpty
            ? nil
            : energyByDay.values.reduce(0, +) / Double(energyByDay.count)

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
            costAllTimeUSD: totalCost,
            pattern: pattern,
            estimatedCaloriesPerLoggedDay: energyAverage,
            energyEstimateDays: energyByDay.count
        )
    }

    private static func patternSnapshot(
        from fingerprinted: [(entry: NutritionEntry, fingerprint: MealFingerprint)],
        recent: [NutritionEntry]
    ) -> NutritionPatternSnapshot {
        let beneficialGroups: Set<MealCategory> = [
            .leafyGreens, .cruciferous, .otherVeg, .fruit, .legumes,
            .wholeGrains, .nutsAndSeeds, .omega3Source, .fermented,
        ]
        let seen = Set(fingerprinted.flatMap(\.fingerprint.categories))
            .intersection(beneficialGroups)
        let mealsWithoutLimitFlags = fingerprinted.filter { pair in
            !pair.fingerprint.categories.contains(where: \.isAvoid)
        }.count
        // Barcode/search entries do not have a photo fingerprint, but Open Food Facts
        // supplies NOVA processing data. Include those entries when it is available.
        let assessedPackagedMeals = recent.filter {
            $0.fingerprint == nil && $0.ultraProcessedScore != nil
        }
        let packagedMealsWithoutLimitFlags = assessedPackagedMeals.filter {
            ($0.ultraProcessedScore ?? 1) < 0.9
        }.count
        return NutritionPatternSnapshot(
            beneficialGroupsSeen: seen.count,
            beneficialGroupTarget: beneficialGroups.count,
            mealsWithoutLimitFlags: mealsWithoutLimitFlags + packagedMealsWithoutLimitFlags,
            assessedMeals: fingerprinted.count + assessedPackagedMeals.count
        )
    }

    // MARK: - Per-bucket rollup

    private static func rollup(
        for bucket: NutrientBucket,
        recent: [NutritionEntry],
        fingerprinted: [(entry: NutritionEntry, fingerprint: MealFingerprint)],
        coverageDays: Int,
        lookbackDays: Int
    ) -> NutritionBucketRollup {
        let value = weeklyValue(for: bucket, recent: recent, fingerprinted: fingerprinted)
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
        recent: [NutritionEntry],
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
            return Double(recent.filter { entry in
                if entry.fingerprint?.contains(.ultraProcessed) == true { return true }
                return (entry.ultraProcessedScore ?? 0) >= 0.9
            }.count)
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
