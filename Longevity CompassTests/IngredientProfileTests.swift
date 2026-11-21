import XCTest
@testable import Longevity_Compass

@MainActor
final class IngredientProfileTests: XCTestCase {
    private func product(_ json: String) throws -> OpenFoodFactsProduct {
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return OpenFoodFactsClient.parse(product: dict, barcode: "123", includesProfile: true)
    }

    func testAllergensTracesLabelsAndNestedIngredients() throws {
        let profile = try XCTUnwrap(product("""
        {
          "product_name": "Pesto",
          "allergens_tags": ["en:milk", "en:nuts", "en:unknown-allergen"],
          "traces_tags": ["en:peanuts", "en:kiwi", "en:peanuts"],
          "labels_tags": ["en:organic", "en:certified-gluten-free"],
          "ingredients": [
            {"id": "en:basil", "is_in_taxonomy": 1},
            {"id": "en:cheese", "is_in_taxonomy": 1, "ingredients": [
              {"id": "en:milk", "is_in_taxonomy": 1},
              {"id": "en:salt", "is_in_taxonomy": 1}
            ]},
            {"id": "en:secret-house-blend", "is_in_taxonomy": 0},
            {"id": "en:salt", "is_in_taxonomy": 1}
          ],
          "ingredients_n": 5,
          "unknown_ingredients_n": 1,
          "states_tags": ["en:ingredients-completed"]
        }
        """).ingredientProfile)

        XCTAssertEqual(profile.origin, .openFoodFacts)
        XCTAssertEqual(profile.allergens, [
            AllergenMark(allergen: .milk, source: .declared),
            AllergenMark(allergen: .treeNuts, source: .declared),
        ])
        XCTAssertEqual(profile.traces, [.peanuts])
        XCTAssertEqual(profile.freeFrom, [FreeFromMark(label: .glutenFree, source: .declared)])
        XCTAssertEqual(profile.ingredientIDs, ["en:basil", "en:cheese", "en:milk", "en:salt"])
        XCTAssertEqual(profile.unmatchedIngredientNames, [])
        XCTAssertEqual(profile.offIngredientsCount, 5)
        XCTAssertEqual(profile.offUnknownIngredientsCount, 1)
        XCTAssertEqual(profile.offIngredientsComplete, false, "one unknown ingredient")
        XCTAssertNil(profile.containsAlcohol)
    }

    func testTruncatedIngredientsKeepCompleteAllergens() throws {
        // Like Nutella: the ingredient list stops after two items, the allergens are complete.
        let profile = try XCTUnwrap(product("""
        {
          "allergens_tags": ["en:milk", "en:nuts", "en:soybeans"],
          "traces_tags": [],
          "labels_tags": ["en:vegetarian"],
          "ingredients": [
            {"id": "en:sugar", "is_in_taxonomy": 1},
            {"id": "en:palm-oil", "is_in_taxonomy": 1}
          ],
          "ingredients_n": 2,
          "unknown_ingredients_n": 0,
          "states_tags": ["en:ingredients-to-be-completed"]
        }
        """).ingredientProfile)

        XCTAssertEqual(profile.allergens.map(\.allergen), [.milk, .treeNuts, .soy])
        XCTAssertEqual(profile.ingredientIDs, ["en:sugar", "en:palm-oil"])
        XCTAssertEqual(profile.offIngredientsComplete, false)
        XCTAssertEqual(profile.freeFrom, [])
    }

    func testCompleteIngredientsNeedStateAndNoUnknowns() throws {
        let profile = try XCTUnwrap(product("""
        {"ingredients": [{"id": "en:oat", "is_in_taxonomy": 1}],
         "unknown_ingredients_n": 0, "states_tags": ["en:ingredients-completed"]}
        """).ingredientProfile)
        XCTAssertEqual(profile.offIngredientsComplete, true)
    }

    func testLactoseFreeChildLabel() throws {
        let profile = try XCTUnwrap(product("""
        {"allergens_tags": ["en:milk"], "labels_tags": ["en:naturally-lactose-free", "en:no-lactose"]}
        """).ingredientProfile)
        XCTAssertEqual(profile.freeFrom, [FreeFromMark(label: .lactoseFree, source: .declared)])
        XCTAssertTrue(profile.contains(.milk))
        XCTAssertNil(profile.offIngredientsComplete, "no states_tags")
    }

    func testAlcohol() throws {
        let beer = try XCTUnwrap(product("""
        {"labels_tags": [], "nutriments": {"alcohol_100g": 5}}
        """).ingredientProfile)
        XCTAssertEqual(beer.containsAlcohol, true)

        let lowAlcohol = try XCTUnwrap(product("""
        {"labels_tags": [], "nutriments": {"alcohol_100g": "0.4"}}
        """).ingredientProfile)
        XCTAssertEqual(lowAlcohol.containsAlcohol, false)

        let labelled = try XCTUnwrap(product("""
        {"labels_tags": ["en:contains-alcohol"]}
        """).ingredientProfile)
        XCTAssertEqual(labelled.containsAlcohol, true)
    }

    func testMissingFieldsGiveNilProfile() throws {
        XCTAssertNil(try product("""
        {"product_name": "Water", "nutriments": {"energy-kcal_100g": 0}}
        """).ingredientProfile)
    }

    func testSearchResultsCarryNoProfile() throws {
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"allergens_tags": ["en:milk"], "labels_tags": ["en:no-gluten"]}
        """.utf8)) as? [String: Any])
        XCTAssertNil(OpenFoodFactsClient.parse(product: dict, barcode: "1").ingredientProfile)
    }

    func testCodableRoundTripOnEntry() throws {
        let profile = IngredientProfile(
            origin: .openFoodFacts,
            allergens: [AllergenMark(allergen: .gluten, source: .declared)],
            traces: [.sesame],
            ingredientIDs: ["en:wheat-flour"],
            unmatchedIngredientNames: [],
            freeFrom: [FreeFromMark(label: .lactoseFree, source: .declared)],
            containsAlcohol: false,
            offIngredientsComplete: true,
            offIngredientsCount: 1,
            offUnknownIngredientsCount: 0
        )
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(IngredientProfile.self, from: data), profile)

        let entry = NutritionEntry(source: .barcode, rawInput: "123", ingredientProfile: profile)
        XCTAssertNotNil(entry.ingredientProfileJSON)
        XCTAssertEqual(entry.ingredientProfile, profile)
        entry.ingredientProfile = nil
        XCTAssertNil(entry.ingredientProfileJSON)
        XCTAssertNil(NutritionEntry(source: .barcode, rawInput: "1").ingredientProfile)
    }
}
