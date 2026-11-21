import DigestionInsightsEngine
import XCTest
@testable import Longevity_Compass

@MainActor
final class ExposureBuilderTests: XCTestCase {
    private let taxonomy = IngredientTaxonomy.shared
    /// 2026-01-01 00:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_767_225_600)
    private var utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func at(day: Double, hour: Double) -> Date {
        t0.addingTimeInterval((day * 24 + hour) * 3600)
    }

    private func off(
        allergens: [AllergenMark] = [],
        traces: [EUAllergen] = [],
        ingredients: [String] = [],
        freeFrom: [FreeFromMark] = [],
        alcohol: Bool? = nil,
        complete: Bool? = nil
    ) -> IngredientProfile {
        IngredientProfile(
            origin: .openFoodFacts, allergens: allergens, traces: traces, ingredientIDs: ingredients,
            unmatchedIngredientNames: [], freeFrom: freeFrom, containsAlcohol: alcohol, offIngredientsComplete: complete
        )
    }

    private func photo(allergens: [AllergenMark] = [], ingredients: [String] = [], freeFrom: [FreeFromMark] = []) -> IngredientProfile {
        IngredientProfile(
            origin: .photoAI, allergens: allergens, traces: [], ingredientIDs: ingredients,
            unmatchedIngredientNames: [], freeFrom: freeFrom
        )
    }

    private func values(_ profile: IngredientProfile) -> [String: Double] {
        ExposureBuilder.exposureValues(for: profile, taxonomy: taxonomy)
    }

    // MARK: - Evidence levels (B7)

    func testAllergenValuesBySource() {
        let v = values(off(allergens: [
            AllergenMark(allergen: .milk, source: .declared),
            AllergenMark(allergen: .gluten, source: .ai),
            AllergenMark(allergen: .eggs, source: .user),
        ]))
        XCTAssertEqual(v["allergen:en:milk"], 1.0)
        XCTAssertEqual(v["allergen:en:gluten"], 0.5)
        XCTAssertEqual(v["allergen:en:eggs"], 1.0)
    }

    func testTracesAreL3AndDeclaredWins() {
        let v = values(off(allergens: [AllergenMark(allergen: .milk, source: .declared)], traces: [.milk, .peanuts]))
        XCTAssertEqual(v["allergen:en:peanuts"], 0.5)
        XCTAssertEqual(v["allergen:en:milk"], 1.0)
    }

    func testOFFCompleteVersusIncompleteIngredients() {
        XCTAssertEqual(values(off(ingredients: ["en:tomato"], complete: true))["ingredient:en:tomato"], 0.85)
        XCTAssertEqual(values(off(ingredients: ["en:tomato"], complete: false))["ingredient:en:tomato"], 0.5)
        XCTAssertEqual(values(off(ingredients: ["en:tomato"], complete: nil))["ingredient:en:tomato"], 0.5)
    }

    func testPhotoIngredientsAreL3() {
        let v = values(photo(ingredients: ["en:tomato"]))
        XCTAssertEqual(v["ingredient:en:tomato"], 0.5)
        XCTAssertEqual(v["group:en:fruit-vegetable"], 0.5)
    }

    func testRollUpAndGroups() {
        let v = values(off(ingredients: ["en:onion-powder", "en:wheat-flour"], complete: true))
        XCTAssertEqual(v["ingredient:en:onion"], 0.85)
        XCTAssertEqual(v["group:en:onion-family-vegetable"], 0.85)
        XCTAssertEqual(v["ingredient:en:wheat"], 0.85)
        XCTAssertEqual(v["group:en:cereal"], 0.85)
        XCTAssertNil(v["ingredient:en:onion-powder"])
    }

    func testMaxPerMealPerFeature() {
        // Milk and cheese both roll up into dairy: one dairy exposure.
        let v = values(photo(ingredients: ["en:milk", "en:cheese"]))
        XCTAssertEqual(v["group:en:dairy"], 0.5)
        // AI allergen plus trace of the same allergen: still L3, once.
        let w = values(off(allergens: [AllergenMark(allergen: .soy, source: .ai)], traces: [.soy]))
        XCTAssertEqual(w["allergen:en:soybeans"], 0.5)
        XCTAssertEqual(w.count, 1)
    }

    func testAlcoholFromOFFAndPhoto() {
        XCTAssertEqual(values(off(alcohol: true))["alcohol"], 1.0)
        XCTAssertNil(values(off(alcohol: false))["alcohol"])
        let wine = values(photo(ingredients: ["en:red-wine"]))
        XCTAssertEqual(wine["alcohol"], 0.5)
        XCTAssertEqual(wine["group:en:alcohol"], 0.5)
        XCTAssertEqual(wine["ingredient:en:wine"], 0.5)
        // OFF beer with alcohol declared: L1 wins over nothing else.
        XCTAssertEqual(values(off(ingredients: ["en:beer"], alcohol: true, complete: true))["alcohol"], 1.0)
    }

    // MARK: - Free-from splits (B4, B8)

    func testFreeFromSplitsMilkGlutenAlcoholCoffee() {
        let v = values(off(
            allergens: [AllergenMark(allergen: .milk, source: .declared), AllergenMark(allergen: .gluten, source: .declared)],
            ingredients: ["en:coffee"],
            freeFrom: [
                FreeFromMark(label: .lactoseFree, source: .declared),
                FreeFromMark(label: .glutenFree, source: .user),
                FreeFromMark(label: .alcoholFree, source: .declared),
                FreeFromMark(label: .decaf, source: .declared),
            ],
            alcohol: true,
            complete: true
        ))
        XCTAssertNil(v["allergen:en:milk"])
        XCTAssertEqual(v["allergen:en:milk+free:en:no-lactose"], 1.0)
        XCTAssertNil(v["allergen:en:gluten"])
        XCTAssertEqual(v["allergen:en:gluten+free:en:no-gluten"], 1.0)
        XCTAssertNil(v["alcohol"])
        XCTAssertEqual(v["alcohol+free:en:no-alcohol"], 1.0)
        XCTAssertNil(v["ingredient:en:coffee"])
        XCTAssertEqual(v["ingredient:en:coffee+free:en:no-caffeine"], 0.85)
    }

    func testFreeFromWithoutBaseAddsNothingAndAIMarksIgnored() {
        let none = values(off(freeFrom: [FreeFromMark(label: .lactoseFree, source: .declared)]))
        XCTAssertTrue(none.isEmpty)
        let ai = values(photo(
            allergens: [AllergenMark(allergen: .milk, source: .ai)],
            freeFrom: [FreeFromMark(label: .lactoseFree, source: .ai)]
        ))
        XCTAssertEqual(ai["allergen:en:milk"], 0.5)
        XCTAssertNil(ai["allergen:en:milk+free:en:no-lactose"])
    }

    // MARK: - Observation windows and history (B3)

    func testWindowsOnlyOnMealDaysWithinPeriods() {
        let periods = [
            ExposureBuilder.Period(start: at(day: 0, hour: 12), end: at(day: 3, hour: 12)),
            ExposureBuilder.Period(start: at(day: 5, hour: 10), end: nil),
        ]
        let meals = [
            ExposureBuilder.Meal(time: at(day: 0, hour: 18), profile: nil),  // day 0 from 12:00
            ExposureBuilder.Meal(time: at(day: 2, hour: 10), profile: nil),  // day 2 whole
            ExposureBuilder.Meal(time: at(day: 5, hour: 9), profile: nil),   // before period 2: day 5 not observed
            ExposureBuilder.Meal(time: at(day: 6, hour: 8), profile: nil),   // day 6 until now
        ]
        let input = ExposureBuilder.build(
            meals: meals, symptoms: [], periods: periods, now: at(day: 6, hour: 12), calendar: utc, taxonomy: taxonomy
        )
        XCTAssertEqual(input.windows, [
            ObservationWindow(start: at(day: 0, hour: 12), end: at(day: 1, hour: 0)),
            ObservationWindow(start: at(day: 2, hour: 0), end: at(day: 3, hour: 0)),
            ObservationWindow(start: at(day: 6, hour: 0), end: at(day: 6, hour: 12)),
        ])
        XCTAssertTrue(input.exposures.isEmpty, "Meals without a profile add no exposures")
    }

    func testAdjacentMealDaysMerge() {
        let periods = [ExposureBuilder.Period(start: at(day: 0, hour: 0), end: at(day: 10, hour: 0))]
        let meals = [0, 1, 2].map { ExposureBuilder.Meal(time: at(day: Double($0), hour: 12), profile: nil) }
        let input = ExposureBuilder.build(meals: meals, symptoms: [], periods: periods, now: at(day: 20, hour: 0), calendar: utc)
        XCTAssertEqual(input.windows, [ObservationWindow(start: at(day: 0, hour: 0), end: at(day: 3, hour: 0))])
    }

    func testNinetySixHourHistory() {
        let start = at(day: 10, hour: 0)
        let periods = [
            ExposureBuilder.Period(start: at(day: 0, hour: 0), end: at(day: 1, hour: 0)),
            ExposureBuilder.Period(start: start, end: nil),
        ]
        let tomato = off(ingredients: ["en:tomato"], complete: true)
        let meals = [
            ExposureBuilder.Meal(time: start.addingTimeInterval(-95 * 3600), profile: tomato),  // history
            ExposureBuilder.Meal(time: start.addingTimeInterval(-97 * 3600), profile: tomato),  // gap, too early
            ExposureBuilder.Meal(time: at(day: 0, hour: 12), profile: tomato),                  // inside period 1
            ExposureBuilder.Meal(time: at(day: 10, hour: 12), profile: tomato),                 // inside period 2
        ]
        let input = ExposureBuilder.build(meals: meals, symptoms: [], periods: periods, now: at(day: 11, hour: 0), calendar: utc)
        let times = input.exposures.filter { $0.featureID == "ingredient:en:tomato" }.map(\.time)
        XCTAssertEqual(times, [at(day: 0, hour: 12), start.addingTimeInterval(-95 * 3600), at(day: 10, hour: 12)])
    }

    func testSymptomsOutsideWindowsDroppedAndKindsObservedOnly() {
        let periods = [ExposureBuilder.Period(start: at(day: 0, hour: 0), end: nil)]
        let meals = [ExposureBuilder.Meal(time: at(day: 0, hour: 8), profile: nil)]
        let symptoms = [
            ExposureBuilder.Symptom(kind: .diarrhoea, onset: at(day: 0, hour: 14), levelRank: 1, isTopLevel: true),
            ExposureBuilder.Symptom(kind: .bloating, onset: at(day: 0, hour: 10), levelRank: 0, isTopLevel: false),
            ExposureBuilder.Symptom(kind: .nausea, onset: at(day: 1, hour: 10), levelRank: 0, isTopLevel: false),  // no meal on day 1
        ]
        let input = ExposureBuilder.build(meals: meals, symptoms: symptoms, periods: periods, now: at(day: 2, hour: 0), calendar: utc)
        XCTAssertEqual(input.symptoms.map(\.kind), ["bloating", "diarrhoea"])
        XCTAssertEqual(input.symptomKinds, ["bloating", "diarrhoea"])
        XCTAssertEqual(input.symptoms.last?.levelRank, 1)
        XCTAssertEqual(input.symptoms.last?.isTopLevel, true)
    }

    func testExposuresSortedAndDeterministic() {
        let periods = [ExposureBuilder.Period(start: at(day: 0, hour: 0), end: nil)]
        let meals = [
            ExposureBuilder.Meal(time: at(day: 0, hour: 18), profile: off(ingredients: ["en:tomato"], complete: true)),
            ExposureBuilder.Meal(time: at(day: 0, hour: 8), profile: off(allergens: [AllergenMark(allergen: .milk, source: .declared)])),
        ]
        let a = ExposureBuilder.build(meals: meals, symptoms: [], periods: periods, now: at(day: 1, hour: 0), calendar: utc)
        let b = ExposureBuilder.build(meals: meals.reversed(), symptoms: [], periods: periods, now: at(day: 1, hour: 0), calendar: utc)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.exposures.map(\.featureID), ["allergen:en:milk", "group:en:fruit-vegetable", "ingredient:en:tomato"])
        XCTAssertEqual(DigestionAnalysis.fingerprint(a), DigestionAnalysis.fingerprint(b))
    }

    // MARK: - Display names (B8)

    func testDisplayNames() {
        XCTAssertEqual(ExposureBuilder.displayName(of: "allergen:en:milk", taxonomy: taxonomy), "Milk")
        XCTAssertEqual(ExposureBuilder.displayName(of: "allergen:en:nuts", taxonomy: taxonomy), "Tree nuts")
        XCTAssertEqual(ExposureBuilder.displayName(of: "ingredient:en:onion", taxonomy: taxonomy), "Onion")
        XCTAssertEqual(ExposureBuilder.displayName(of: "group:en:dairy", taxonomy: taxonomy), "Dairy")
        XCTAssertEqual(ExposureBuilder.displayName(of: "alcohol", taxonomy: taxonomy), "Alcohol")
        XCTAssertEqual(ExposureBuilder.displayName(of: "allergen:en:milk+free:en:no-lactose", taxonomy: taxonomy), "Milk (lactose-free)")
        XCTAssertEqual(ExposureBuilder.displayName(of: "ingredient:en:coffee+free:en:no-caffeine", taxonomy: taxonomy), "Coffee (decaf)")
        XCTAssertEqual(ExposureBuilder.displayName(of: "alcohol+free:en:no-alcohol", taxonomy: taxonomy), "Alcohol (alcohol-free)")
        XCTAssertEqual(ExposureBuilder.featureKindLabel(of: "allergen:en:milk"), "Allergen")
        XCTAssertEqual(ExposureBuilder.featureKindLabel(of: "group:en:dairy"), "Food group")
        XCTAssertEqual(ExposureBuilder.featureKindLabel(of: "ingredient:en:milk"), "Ingredient")
    }
}
