import Foundation

/// Coarse food categories used by the AI fingerprint flow. A single meal can carry
/// multiple categories (e.g. fried chicken → leanProtein AND fried).
/// Categories are chosen for longevity relevance, not nutritional precision.
enum MealCategory: String, Codable, CaseIterable, Identifiable {
    case leafyGreens
    case cruciferous
    case otherVeg
    case fruit
    case legumes
    case wholeGrains
    case refinedCarbs
    case nutsAndSeeds
    case omega3Source
    case leanProtein
    case redMeat
    case processedMeat
    case dairyOrAlt
    case fermented
    case ultraProcessed
    case fried
    case sugaryDrinks

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .leafyGreens:    "Leafy greens"
        case .cruciferous:    "Cruciferous"
        case .otherVeg:       "Other veg"
        case .fruit:          "Fruit"
        case .legumes:        "Legumes"
        case .wholeGrains:    "Whole grains"
        case .refinedCarbs:   "Refined carbs"
        case .nutsAndSeeds:   "Nuts & seeds"
        case .omega3Source:   "Omega-3 source"
        case .leanProtein:    "Lean protein"
        case .redMeat:        "Red meat"
        case .processedMeat:  "Processed meat"
        case .dairyOrAlt:     "Dairy / alt"
        case .fermented:      "Fermented"
        case .ultraProcessed: "Ultra-processed"
        case .fried:          "Fried"
        case .sugaryDrinks:   "Sugary drinks"
        }
    }

    var systemImage: String {
        switch self {
        case .leafyGreens:    "leaf"
        case .cruciferous:    "leaf.fill"
        case .otherVeg:       "carrot"
        case .fruit:          "applelogo"
        case .legumes:        "circle.grid.2x2"
        case .wholeGrains:    "rectangle.stack"
        case .refinedCarbs:   "rectangle.fill"
        case .nutsAndSeeds:   "circle.hexagongrid"
        case .omega3Source:   "fish"
        case .leanProtein:    "fork.knife"
        case .redMeat:        "circle.fill"
        case .processedMeat:  "exclamationmark.octagon"
        case .dairyOrAlt:     "drop"
        case .fermented:      "bubbles.and.sparkles"
        case .ultraProcessed: "shippingbox"
        case .fried:          "flame"
        case .sugaryDrinks:   "cup.and.saucer"
        }
    }

    /// True for whole-food plant categories — used to count "plant variety per week."
    var isPlantSource: Bool {
        switch self {
        case .leafyGreens, .cruciferous, .otherVeg, .fruit,
             .legumes, .wholeGrains, .nutsAndSeeds: true
        default: false
        }
    }

    /// True for categories where we want fewer meals, not more.
    var isAvoid: Bool {
        switch self {
        case .processedMeat, .ultraProcessed, .fried,
             .sugaryDrinks, .refinedCarbs: true
        default: false
        }
    }
}

/// Codable payload stored on `NutritionEntry.fingerprintJSON`. One fingerprint per meal.
nonisolated struct MealFingerprint: Codable, Equatable {
    struct Item: Codable, Equatable {
        let category: MealCategory
        /// Visual fraction of the plate this category occupies, 0...1.
        let plateFraction: Double
    }

    let items: [Item]
    /// Free-form short list of distinct plant ingredient names ("kale", "carrot", "lentils").
    /// Used for "unique plants per week" tallies.
    let plantIngredients: [String]
    let aiNotes: String?
    let confidence: String?
    /// Short human-readable meal title from the AI, e.g. "Grilled salmon with rice & broccoli".
    /// Nil on legacy entries logged before the title field existed.
    let title: String?

    // MARK: - Per-100 g macro estimates (nil when the AI couldn't estimate)
    let estimatedKcalPer100g: Double?
    let proteinPer100g: Double?
    let carbsPer100g: Double?
    let fatPer100g: Double?
    /// Nil on entries logged before the AI was asked for fibre.
    let fiberPer100g: Double?
    /// AI's best-guess typical serving weight; used to pre-fill the weight field in the capture flow.
    let typicalServingGrams: Double?

    var categories: Set<MealCategory> { Set(items.map(\.category)) }

    func contains(_ category: MealCategory) -> Bool {
        categories.contains(category)
    }

    var hasMacroEstimates: Bool { estimatedKcalPer100g != nil }

    func scaledMacros(
        toGrams grams: Double
    ) -> (kcal: Double, protein: Double, carbs: Double, fat: Double, fiber: Double?)? {
        guard let kcal = estimatedKcalPer100g,
              let protein = proteinPer100g,
              let carbs = carbsPer100g,
              let fat = fatPer100g else { return nil }
        let f = grams / 100.0
        return (kcal * f, protein * f, carbs * f, fat * f, fiberPer100g.map { $0 * f })
    }
}
