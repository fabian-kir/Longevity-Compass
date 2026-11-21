import DigestionInsightsEngine
import Foundation

/// Turns the nutrition journal, symptom log and tracking periods into the
/// engine's `AnalysisInput`. Pure: same data in, same input (and fingerprint) out.
///
/// Rules (docs/digestion-insights-methodology.md § 2):
/// - Observation: a calendar day inside a tracking period with at least one
///   meal logged inside the period is observed; days without a meal and gaps
///   between periods are not.
/// - Exposures: meals from 96 h before a period start until its end; per meal
///   and feature the highest evidence value counts.
/// - Symptoms outside the observation windows are dropped.
enum ExposureBuilder {
    struct Meal: Equatable {
        var time: Date
        var profile: IngredientProfile?
    }

    struct Symptom: Equatable {
        var kind: SymptomKind
        var onset: Date
        var levelRank: Int
        var isTopLevel: Bool
    }

    struct Period: Equatable {
        var start: Date
        var end: Date?
    }

    typealias Values = HealthThresholds.Digestion

    // MARK: - Input

    static func build(
        nutrition: [NutritionEntry],
        symptoms: [SymptomEntry],
        periods: [DigestionTrackingPeriod],
        now: Date,
        calendar: Calendar = .current,
        taxonomy: IngredientTaxonomy = .shared,
        config: AnalysisConfig = AnalysisConfig(seed: 0)
    ) -> AnalysisInput {
        build(
            meals: nutrition.map { Meal(time: $0.date, profile: $0.ingredientProfile) },
            symptoms: symptoms.compactMap { entry in
                guard let kind = entry.kind, let rank = entry.rank else { return nil }
                return Symptom(kind: kind, onset: entry.onset, levelRank: rank, isTopLevel: entry.isTopLevel)
            },
            periods: periods.map { Period(start: $0.start, end: $0.end) },
            now: now,
            calendar: calendar,
            taxonomy: taxonomy,
            config: config
        )
    }

    static func build(
        meals: [Meal],
        symptoms: [Symptom],
        periods: [Period],
        now: Date,
        calendar: Calendar = .current,
        taxonomy: IngredientTaxonomy = .shared,
        config: AnalysisConfig = AnalysisConfig(seed: 0)
    ) -> AnalysisInput {
        let spans = periods
            .map { (start: $0.start, end: min($0.end ?? now, now)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        let windows = observationWindows(mealTimes: meals.map(\.time), spans: spans, calendar: calendar)

        let history = Values.historyHours * 3600
        var exposures: [ExposureEvent] = []
        for meal in meals {
            guard let profile = meal.profile,
                  spans.contains(where: { meal.time >= $0.start.addingTimeInterval(-history) && meal.time <= $0.end })
            else { continue }
            for (feature, value) in exposureValues(for: profile, taxonomy: taxonomy) {
                exposures.append(ExposureEvent(featureID: feature, time: meal.time, value: value))
            }
        }
        exposures.sort { ($0.time, $0.featureID) < ($1.time, $1.featureID) }

        let kept = symptoms
            .filter { symptom in windows.contains { symptom.onset >= $0.start && symptom.onset < $0.end } }
            .sorted { ($0.onset, kindOrder($0.kind)) < ($1.onset, kindOrder($1.kind)) }
        let kinds = SymptomKind.allCases.filter { kind in kept.contains { $0.kind == kind } }

        return AnalysisInput(
            exposures: exposures,
            symptoms: kept.map {
                SymptomEvent(kind: $0.kind.rawValue, onset: $0.onset, levelRank: $0.levelRank, isTopLevel: $0.isTopLevel)
            },
            windows: windows,
            symptomKinds: kinds.map(\.rawValue),
            config: config
        )
    }

    private static func kindOrder(_ kind: SymptomKind) -> Int {
        SymptomKind.allCases.firstIndex(of: kind) ?? 0
    }

    // MARK: - Observation windows

    /// One window per observed day (clipped to its period), adjacent windows merged.
    static func observationWindows(
        mealTimes: [Date],
        spans: [(start: Date, end: Date)],
        calendar: Calendar
    ) -> [ObservationWindow] {
        var pieces: [ObservationWindow] = []
        for span in spans {
            let mealDays = Set(mealTimes.filter { $0 >= span.start && $0 <= span.end }.map { calendar.startOfDay(for: $0) })
            for day in mealDays {
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
                let start = max(day, span.start)
                let end = min(next, span.end)
                if end > start { pieces.append(ObservationWindow(start: start, end: end)) }
            }
        }
        pieces.sort { $0.start < $1.start }
        var merged: [ObservationWindow] = []
        for piece in pieces {
            if let last = merged.last, piece.start <= last.end {
                merged[merged.count - 1].end = max(last.end, piece.end)
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    // MARK: - Exposures per meal

    /// Feature ID → exposure value for one meal (B7, B8). Highest value per feature.
    static func exposureValues(for profile: IngredientProfile, taxonomy: IngredientTaxonomy) -> [String: Double] {
        var values: [String: Double] = [:]
        func add(_ feature: String, _ value: Double) {
            values[feature] = max(values[feature] ?? 0, value)
        }

        for mark in profile.allergens {
            add(allergenID(mark.allergen), value(of: mark.source))
        }
        for allergen in profile.traces {
            add(allergenID(allergen), Values.uncertainValue)
        }

        let ingredientValue: Double
        switch profile.origin {
        case .openFoodFacts:
            ingredientValue = profile.offIngredientsComplete == true ? Values.completeIngredientsValue : Values.uncertainValue
        case .photoAI:
            ingredientValue = Values.uncertainValue
        }
        var photoAlcohol = false
        for leaf in profile.ingredientIDs {
            let rolled = DigestionCatalog.rollUp(leafID: leaf, taxonomy: taxonomy)
            for feature in rolled.ingredientFeatureIDs + rolled.groupFeatureIDs {
                add(feature, ingredientValue)
            }
            if profile.origin == .photoAI,
               leaf == "en:alcohol" || taxonomy.ancestors(of: leaf).contains("en:alcohol") {
                photoAlcohol = true
            }
        }

        if profile.containsAlcohol == true { add(alcoholID, Values.declaredValue) }
        if photoAlcohol { add(alcoholID, Values.uncertainValue) }

        // Free-from labels (declared or user) replace the base feature for this meal.
        for mark in profile.freeFrom where mark.source != .ai {
            let base = splitTarget(of: mark.label)
            guard let value = values.removeValue(forKey: base) else { continue }
            add(base + "+free:" + mark.label.rawValue, value)
        }
        return values
    }

    static let alcoholID = "alcohol"

    static func allergenID(_ allergen: EUAllergen) -> String {
        "allergen:" + allergen.rawValue
    }

    /// Base feature a free-from label splits (B4).
    static func splitTarget(of label: FreeFromLabel) -> String {
        switch label {
        case .lactoseFree: allergenID(.milk)
        case .glutenFree:  allergenID(.gluten)
        case .alcoholFree: alcoholID
        case .decaf:       "ingredient:en:coffee"
        }
    }

    private static func value(of source: EvidenceSource) -> Double {
        switch source {
        case .declared, .user: Values.declaredValue
        case .ai:              Values.uncertainValue
        }
    }

    // MARK: - Display names

    /// "Milk", "Onion", "Onion family vegetable", "Alcohol", "Milk (lactose-free)".
    static func displayName(of featureID: String, taxonomy: IngredientTaxonomy = .shared) -> String {
        let parts = featureID.components(separatedBy: "+free:")
        let suffix = parts.count > 1 ? (FreeFromLabel(rawValue: parts[1])?.displaySuffix ?? "") : ""
        let base = parts[0]
        let name: String
        if base == alcoholID {
            name = "Alcohol"
        } else if base.hasPrefix("allergen:") {
            let raw = String(base.dropFirst("allergen:".count))
            name = EUAllergen(rawValue: raw)?.label ?? raw
        } else if let colon = base.firstIndex(of: ":") {
            let id = String(base[base.index(after: colon)...])
            name = capitalised(taxonomy.name(of: id) ?? readable(id))
        } else {
            name = base
        }
        return name + suffix
    }

    /// "Allergen", "Ingredient", "Food group", "Drink"; shown under the name so
    /// that e.g. allergen Milk and ingredient Milk can be told apart.
    static func featureKindLabel(of featureID: String) -> String {
        if featureID.hasPrefix("allergen:") { return "Allergen" }
        if featureID.hasPrefix("group:") { return "Food group" }
        if featureID.hasPrefix(alcoholID) { return "Drink" }
        return "Ingredient"
    }

    private static func readable(_ taxonomyID: String) -> String {
        let bare = taxonomyID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? taxonomyID
        return bare.replacingOccurrences(of: "-", with: " ")
    }

    private static func capitalised(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }
}
