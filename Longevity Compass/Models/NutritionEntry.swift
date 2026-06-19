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
        imageFileName: String? = nil
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
}
