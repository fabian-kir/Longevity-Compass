import Foundation

/// The 14 allergens EU food law requires on labels. Raw values are Open Food
/// Facts allergen IDs, so `allergens_tags` maps onto them directly.
nonisolated enum EUAllergen: String, CaseIterable, Codable, Identifiable {
    case gluten = "en:gluten"
    case crustaceans = "en:crustaceans"
    case eggs = "en:eggs"
    case fish = "en:fish"
    case peanuts = "en:peanuts"
    case soy = "en:soybeans"
    case milk = "en:milk"
    case treeNuts = "en:nuts"
    case celery = "en:celery"
    case mustard = "en:mustard"
    case sesame = "en:sesame-seeds"
    case sulphites = "en:sulphur-dioxide-and-sulphites"
    case lupin = "en:lupin"
    case molluscs = "en:molluscs"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gluten:      "Gluten"
        case .crustaceans: "Crustaceans"
        case .eggs:        "Eggs"
        case .fish:        "Fish"
        case .peanuts:     "Peanuts"
        case .soy:         "Soy"
        case .milk:        "Milk"
        case .treeNuts:    "Tree nuts"
        case .celery:      "Celery"
        case .mustard:     "Mustard"
        case .sesame:      "Sesame"
        case .sulphites:   "Sulphites"
        case .lupin:       "Lupin"
        case .molluscs:    "Molluscs"
        }
    }
}

/// Free-from claims that split a feature in Digestion Insights. Raw values are
/// Open Food Facts label IDs; child labels (e.g. `en:certified-gluten-free`)
/// count too, see `IngredientTaxonomy.freeFromLabel(forLabelTag:)`.
nonisolated enum FreeFromLabel: String, CaseIterable, Codable, Identifiable {
    case lactoseFree = "en:no-lactose"
    case glutenFree = "en:no-gluten"
    case alcoholFree = "en:no-alcohol"
    case decaf = "en:no-caffeine"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lactoseFree: "Lactose-free"
        case .glutenFree:  "Gluten-free"
        case .alcoholFree: "Alcohol-free"
        case .decaf:       "Decaf"
        }
    }

    /// Appended to a feature's display name, e.g. "Milk (lactose-free)".
    var displaySuffix: String {
        switch self {
        case .lactoseFree: " (lactose-free)"
        case .glutenFree:  " (gluten-free)"
        case .alcoholFree: " (alcohol-free)"
        case .decaf:       " (decaf)"
        }
    }
}

/// Where a mark came from. `declared` = Open Food Facts label data.
nonisolated enum EvidenceSource: String, Codable {
    case declared, ai, user
}

nonisolated enum ProfileOrigin: String, Codable {
    case openFoodFacts, photoAI
}

nonisolated struct AllergenMark: Codable, Equatable {
    var allergen: EUAllergen
    var source: EvidenceSource
}

nonisolated struct FreeFromMark: Codable, Equatable {
    var label: FreeFromLabel
    var source: EvidenceSource
}

/// What a meal contained, as far as labels or the photo AI can tell. Stored as
/// JSON on `NutritionEntry.ingredientProfileJSON`; nil there means unknown.
nonisolated struct IngredientProfile: Codable, Equatable {
    var schemaVersion: Int = 1
    var origin: ProfileOrigin
    var allergens: [AllergenMark]
    /// "May contain" allergens from Open Food Facts.
    var traces: [EUAllergen]
    /// Taxonomy IDs as listed (leaves); IDs unknown to the taxonomy are left out.
    var ingredientIDs: [String]
    /// Display only, never analysed.
    var unmatchedIngredientNames: [String]
    var freeFrom: [FreeFromMark]
    /// Open Food Facts: nutriment `alcohol_100g` > 0.5 or label `en:contains-alcohol`.
    var containsAlcohol: Bool?
    /// Open Food Facts only: `states_tags` has `en:ingredients-completed` and `unknown_ingredients_n` == 0.
    var offIngredientsComplete: Bool?
    var offIngredientsCount: Int?
    var offUnknownIngredientsCount: Int?

    func contains(_ allergen: EUAllergen) -> Bool {
        allergens.contains { $0.allergen == allergen }
    }

    func isFree(from label: FreeFromLabel) -> Bool {
        freeFrom.contains { $0.label == label }
    }

    func source(of allergen: EUAllergen) -> EvidenceSource? {
        allergens.first { $0.allergen == allergen }?.source
    }

    // MARK: - Manual review

    /// Ticking adds a `user` mark; unticking removes the mark. An untouched AI
    /// mark keeps `ai`, and an AI mark switched off then on again becomes `user`.
    func settingAllergen(_ allergen: EUAllergen, present: Bool) -> IngredientProfile {
        var copy = self
        let wasPresent = contains(allergen)
        if present && !wasPresent {
            copy.allergens.append(AllergenMark(allergen: allergen, source: .user))
            copy.allergens.sort { Self.allergenOrder($0.allergen) < Self.allergenOrder($1.allergen) }
        } else if !present {
            copy.allergens.removeAll { $0.allergen == allergen }
        }
        return copy
    }

    func settingFreeFrom(_ label: FreeFromLabel, present: Bool) -> IngredientProfile {
        var copy = self
        copy.freeFrom.removeAll { $0.label == label }
        if present {
            copy.freeFrom.append(FreeFromMark(label: label, source: .user))
            copy.freeFrom.sort { Self.freeFromOrder($0.label) < Self.freeFromOrder($1.label) }
        }
        return copy
    }

    private static func allergenOrder(_ allergen: EUAllergen) -> Int {
        EUAllergen.allCases.firstIndex(of: allergen) ?? 0
    }

    private static func freeFromOrder(_ label: FreeFromLabel) -> Int {
        FreeFromLabel.allCases.firstIndex(of: label) ?? 0
    }
}

extension EUAllergen {
    /// Known allergens in input order, without duplicates. Unknown strings are dropped.
    nonisolated static func parse(_ raw: [String]) -> [EUAllergen] {
        var out: [EUAllergen] = []
        for value in raw {
            guard let allergen = EUAllergen(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                  !out.contains(allergen) else { continue }
            out.append(allergen)
        }
        return out
    }
}

extension IngredientProfile {
    /// Starting point when the user reviews a photo meal that has no profile yet.
    static var emptyPhoto: IngredientProfile {
        IngredientProfile(
            origin: .photoAI,
            allergens: [],
            traces: [],
            ingredientIDs: [],
            unmatchedIngredientNames: [],
            freeFrom: []
        )
    }

    /// Profile of a photo meal. Allergens count as `ai`; names the taxonomy
    /// cannot match are kept for display only. The AI never sets free-from
    /// labels. Nil for fingerprints from before the AI was asked for either field.
    static func fromFingerprint(_ fingerprint: MealFingerprint, taxonomy: IngredientTaxonomy) -> IngredientProfile? {
        guard fingerprint.allergens != nil || fingerprint.ingredients != nil else { return nil }
        var ids: [String] = []
        var unmatched: [String] = []
        for name in fingerprint.ingredients ?? [] {
            if let id = taxonomy.id(forName: name) {
                if !ids.contains(id) { ids.append(id) }
            } else {
                let trimmed = IngredientTaxonomy.normalize(name)
                if !trimmed.isEmpty && !unmatched.contains(trimmed) { unmatched.append(trimmed) }
            }
        }
        return IngredientProfile(
            origin: .photoAI,
            allergens: EUAllergen.parse(fingerprint.allergens ?? []).map { AllergenMark(allergen: $0, source: .ai) },
            traces: [],
            ingredientIDs: ids,
            unmatchedIngredientNames: unmatched,
            freeFrom: []
        )
    }
}
