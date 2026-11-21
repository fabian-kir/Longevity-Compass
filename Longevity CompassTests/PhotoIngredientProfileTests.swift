import XCTest
@testable import Longevity_Compass

@MainActor
final class PhotoIngredientProfileTests: XCTestCase {
    private let taxonomy = IngredientTaxonomy.shared

    private let legacyJSON = """
    {"items": [{"category": "otherVeg", "plateFraction": 0.5}], "plantIngredients": ["onion"],
     "aiNotes": null, "confidence": "high", "title": "Onion soup"}
    """

    private let currentJSON = """
    {"items": [{"category": "refinedCarbs", "plateFraction": 0.6}], "plantIngredients": ["tomato"],
     "aiNotes": null, "confidence": "medium", "title": "Spaghetti",
     "estimatedKcalPer100g": 150, "proteinPer100g": 5, "carbsPer100g": 25, "fatPer100g": 3,
     "fiberPer100g": 2, "typicalServingGrams": 400,
     "allergens": ["en:gluten", "en:milk", "en:peanut-butter", "EN:MILK"],
     "ingredients": ["Wheat Flour", "tomato", "onions", "zwiebel", "secret sauce", "secret sauce"]}
    """

    private func fingerprint(_ json: String) throws -> MealFingerprint {
        try OpenRouterClient.parseFingerprint(json)
    }

    func testDecodesWithAndWithoutNewFields() throws {
        let legacy = try fingerprint(legacyJSON)
        XCTAssertNil(legacy.allergens)
        XCTAssertNil(legacy.ingredients)
        XCTAssertNil(IngredientProfile.fromFingerprint(legacy, taxonomy: taxonomy))

        let current = try fingerprint(currentJSON)
        XCTAssertEqual(current.allergens, ["en:gluten", "en:milk"])
        XCTAssertEqual(current.ingredients, ["wheat flour", "tomato", "onions", "zwiebel", "secret sauce"])
    }

    func testInvalidAllergenDropped() throws {
        let fp = try fingerprint("""
        {"items": [], "plantIngredients": [], "allergens": ["en:kiwi", "gluten", "en:sesame-seeds"]}
        """)
        XCTAssertEqual(fp.allergens, ["en:sesame-seeds"])
    }

    func testIngredientsCappedAtFifteen() throws {
        let names = (1...20).map { "\"item \($0)\"" }.joined(separator: ",")
        let fp = try fingerprint("""
        {"items": [], "plantIngredients": [], "ingredients": [\(names)]}
        """)
        XCTAssertEqual(fp.ingredients?.count, 15)
    }

    func testProfileMatchesNamesAndKeepsUnmatched() throws {
        let profile = try XCTUnwrap(IngredientProfile.fromFingerprint(try fingerprint(currentJSON), taxonomy: taxonomy))
        XCTAssertEqual(profile.origin, .photoAI)
        XCTAssertEqual(profile.allergens, [
            AllergenMark(allergen: .gluten, source: .ai),
            AllergenMark(allergen: .milk, source: .ai),
        ])
        XCTAssertEqual(profile.ingredientIDs, ["en:wheat-flour", "en:tomato", "en:onion"])
        XCTAssertEqual(profile.unmatchedIngredientNames, ["secret sauce"])
        XCTAssertEqual(profile.freeFrom, [])
        XCTAssertEqual(profile.traces, [])
    }

    func testEntryFromFingerprintCarriesProfile() throws {
        let analysis = MealFingerprintAnalysis(
            fingerprint: try fingerprint(currentJSON), model: "test", inputTokens: 0, outputTokens: 0, costUSD: 0
        )
        let entry = NutritionEntry.fromFingerprint(analysis, capturedAt: .now, portionGrams: 400)
        XCTAssertEqual(entry.ingredientProfile?.ingredientIDs, ["en:wheat-flour", "en:tomato", "en:onion"])
        XCTAssertEqual(entry.fingerprint?.allergens, ["en:gluten", "en:milk"])
    }

    // MARK: - Toggle provenance

    private var aiProfile: IngredientProfile {
        var profile = IngredientProfile.emptyPhoto
        profile.allergens = [AllergenMark(allergen: .gluten, source: .ai), AllergenMark(allergen: .milk, source: .ai)]
        return profile
    }

    func testToggleOnGivesUserSource() {
        let profile = aiProfile.settingAllergen(.eggs, present: true)
        XCTAssertEqual(profile.source(of: .eggs), .user)
        XCTAssertEqual(profile.allergens.map(\.allergen), [.gluten, .eggs, .milk], "kept in EU list order")
    }

    func testUntouchedAIMarksKeepAI() {
        let profile = aiProfile.settingAllergen(.eggs, present: true).settingAllergen(.gluten, present: true)
        XCTAssertEqual(profile.source(of: .gluten), .ai)
        XCTAssertEqual(profile.source(of: .milk), .ai)
    }

    func testToggleOffRemovesMark() {
        let profile = aiProfile.settingAllergen(.milk, present: false)
        XCTAssertFalse(profile.contains(.milk))
        XCTAssertEqual(profile.allergens, [AllergenMark(allergen: .gluten, source: .ai)])
    }

    func testAIMarkOffThenOnBecomesUser() {
        let profile = aiProfile.settingAllergen(.milk, present: false).settingAllergen(.milk, present: true)
        XCTAssertEqual(profile.source(of: .milk), .user)
    }

    func testFreeFromTogglesGiveUserSource() {
        let on = aiProfile.settingFreeFrom(.lactoseFree, present: true)
        XCTAssertEqual(on.freeFrom, [FreeFromMark(label: .lactoseFree, source: .user)])
        XCTAssertEqual(on.settingFreeFrom(.lactoseFree, present: false).freeFrom, [])
    }

    // MARK: - Edit save

    func testEditKeepsAllergensAndIngredients() throws {
        let original = try fingerprint(currentJSON)
        let edited = original.edited(
            items: [MealFingerprint.Item(category: .wholeGrains, plateFraction: 0.4)],
            plantIngredients: ["tomato", "basil"],
            aiNotes: "home made",
            title: "Wholegrain spaghetti"
        )
        XCTAssertEqual(edited.allergens, original.allergens)
        XCTAssertEqual(edited.ingredients, original.ingredients)
        XCTAssertEqual(edited.typicalServingGrams, original.typicalServingGrams)
        XCTAssertEqual(edited.title, "Wholegrain spaghetti")

        let decoded = try JSONDecoder().decode(MealFingerprint.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(decoded, edited)
    }
}
