import Foundation
import SwiftData

enum NutritionSource: String, Codable, CaseIterable {
    case barcode
    case photo

    var displayLabel: String {
        switch self {
        case .barcode: "Barcode"
        case .photo:   "Photo"
        }
    }

    var systemImage: String {
        switch self {
        case .barcode: "barcode.viewfinder"
        case .photo:   "camera"
        }
    }
}

@Model
final class NutritionEntry {
    var id: UUID
    var date: Date
    var sourceRaw: String
    var rawInput: String
    var productName: String?

    var caloriesKcal: Double?
    var portionGrams: Double?
    var proteinGrams: Double?
    var fiberGrams: Double?
    var carbsGrams: Double?
    var fatGrams: Double?
    var saturatedFatGrams: Double?
    var addedSugarGrams: Double?
    var sodiumMilligrams: Double?
    var isFattyFish: Bool?
    var leafyGreenServings: Double?
    var ultraProcessedScore: Double?

    var aiNotes: String?
    var modelUsed: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?

    /// JSON-encoded `MealFingerprint`. Photo-source entries set this; barcode and legacy entries leave it nil.
    var fingerprintJSON: String?

    /// Filename of the persisted meal photo inside `MealImageStore`. Nil for legacy entries
    /// and any entry the user logged without saving the source image.
    var imageFileName: String?

    /// JSON-encoded `IngredientProfile`. Nil means unknown: the meal adds no
    /// Digestion Insights exposures but still marks the day as observed.
    var ingredientProfileJSON: String?

    init(
        id: UUID = UUID(),
        date: Date = .now,
        source: NutritionSource,
        rawInput: String,
        productName: String? = nil,
        caloriesKcal: Double? = nil,
        portionGrams: Double? = nil,
        proteinGrams: Double? = nil,
        fiberGrams: Double? = nil,
        carbsGrams: Double? = nil,
        fatGrams: Double? = nil,
        saturatedFatGrams: Double? = nil,
        addedSugarGrams: Double? = nil,
        sodiumMilligrams: Double? = nil,
        isFattyFish: Bool? = nil,
        leafyGreenServings: Double? = nil,
        ultraProcessedScore: Double? = nil,
        aiNotes: String? = nil,
        modelUsed: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        costUSD: Double? = nil,
        fingerprintJSON: String? = nil,
        imageFileName: String? = nil,
        ingredientProfile: IngredientProfile? = nil
    ) {
        self.id = id
        self.date = date
        self.sourceRaw = source.rawValue
        self.rawInput = rawInput
        self.productName = productName
        self.caloriesKcal = caloriesKcal
        self.portionGrams = portionGrams
        self.proteinGrams = proteinGrams
        self.fiberGrams = fiberGrams
        self.carbsGrams = carbsGrams
        self.fatGrams = fatGrams
        self.saturatedFatGrams = saturatedFatGrams
        self.addedSugarGrams = addedSugarGrams
        self.sodiumMilligrams = sodiumMilligrams
        self.isFattyFish = isFattyFish
        self.leafyGreenServings = leafyGreenServings
        self.ultraProcessedScore = ultraProcessedScore
        self.aiNotes = aiNotes
        self.modelUsed = modelUsed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.fingerprintJSON = fingerprintJSON
        self.imageFileName = imageFileName
        self.ingredientProfileJSON = Self.encode(ingredientProfile)
    }

    var source: NutritionSource { NutritionSource(rawValue: sourceRaw) ?? .photo }

    var displayTitle: String {
        productName ?? (rawInput.isEmpty ? source.displayLabel : rawInput)
    }

    var fingerprint: MealFingerprint? {
        guard let json = fingerprintJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MealFingerprint.self, from: data)
    }

    var ingredientProfile: IngredientProfile? {
        get {
            guard let json = ingredientProfileJSON,
                  let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(IngredientProfile.self, from: data)
        }
        set { ingredientProfileJSON = Self.encode(newValue) }
    }

    private static func encode(_ profile: IngredientProfile?) -> String? {
        guard let profile, let data = try? JSONEncoder().encode(profile) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension NutritionEntry {
    /// True when the entry has something to scale: AI per-100 g estimates or a known portion.
    var canRescalePortion: Bool {
        fingerprint?.hasMacroEstimates == true || (portionGrams ?? 0) > 0
    }

    /// Sets a new portion and scales the nutrients with it. Photo entries recompute
    /// from the AI's per-100 g estimates; other entries scale by the ratio to the old portion.
    func rescale(toPortionGrams grams: Double) {
        guard grams > 0 else { return }
        if let scaled = fingerprint?.scaledMacros(toGrams: grams) {
            caloriesKcal = scaled.kcal
            proteinGrams = scaled.protein
            carbsGrams = scaled.carbs
            fatGrams = scaled.fat
            fiberGrams = scaled.fiber
        } else if let old = portionGrams, old > 0 {
            let factor = grams / old
            caloriesKcal = caloriesKcal.map { $0 * factor }
            proteinGrams = proteinGrams.map { $0 * factor }
            fiberGrams = fiberGrams.map { $0 * factor }
            carbsGrams = carbsGrams.map { $0 * factor }
            fatGrams = fatGrams.map { $0 * factor }
            saturatedFatGrams = saturatedFatGrams.map { $0 * factor }
            addedSugarGrams = addedSugarGrams.map { $0 * factor }
            sodiumMilligrams = sodiumMilligrams.map { $0 * factor }
        } else {
            return
        }
        portionGrams = grams
    }
}
