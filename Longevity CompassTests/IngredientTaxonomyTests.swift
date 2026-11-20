import XCTest
@testable import Longevity_Compass

@MainActor
final class IngredientTaxonomyTests: XCTestCase {
    private let taxonomy = IngredientTaxonomy.shared

    func testBundledTaxonomyLoads() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "OFFIngredientTaxonomy", withExtension: "json"))
        let loaded = try IngredientTaxonomy(data: Data(contentsOf: url))
        XCTAssertGreaterThan(loaded.count, 5000)
        XCTAssertGreaterThan(taxonomy.count, 5000)
        XCTAssertTrue(taxonomy.license.contains("ODbL"))
    }

    func testAncestorsAreTransitive() {
        let ancestors = taxonomy.ancestors(of: "en:onion-powder")
        XCTAssertTrue(ancestors.contains("en:onion"))
        XCTAssertTrue(ancestors.contains("en:onion-family-vegetable"))
        XCTAssertFalse(ancestors.contains("en:onion-powder"))
        XCTAssertEqual(taxonomy.parents(of: "en:onion-powder"), ["en:onion"])
    }

    func testNameMatching() {
        XCTAssertEqual(taxonomy.id(forName: "onion"), "en:onion")
        XCTAssertEqual(taxonomy.id(forName: "onions"), "en:onion")
        XCTAssertEqual(taxonomy.id(forName: "  Wheat   Flour "), "en:wheat-flour")
        XCTAssertEqual(taxonomy.id(forName: "Zwiebel"), "en:onion")
        XCTAssertNil(taxonomy.id(forName: "onio"))
        XCTAssertNil(taxonomy.id(forName: ""))
        XCTAssertEqual(taxonomy.name(of: "en:onion"), "onion")
    }

    func testFreeFromChildLabels() {
        XCTAssertEqual(taxonomy.freeFromLabel(forLabelTag: "en:no-lactose"), .lactoseFree)
        XCTAssertEqual(taxonomy.freeFromLabel(forLabelTag: "en:naturally-lactose-free"), .lactoseFree)
        XCTAssertEqual(taxonomy.freeFromLabel(forLabelTag: "en:certified-gluten-free"), .glutenFree)
        XCTAssertEqual(taxonomy.freeFromLabel(forLabelTag: "en:gfco-gluten-free"), .glutenFree)
        XCTAssertNil(taxonomy.freeFromLabel(forLabelTag: "en:organic"))
    }

    func testRollUpToBaseAndGroup() {
        let onionPowder = DigestionCatalog.rollUp(leafID: "en:onion-powder", taxonomy: taxonomy)
        XCTAssertEqual(onionPowder.ingredientFeatureIDs, ["ingredient:en:onion"])
        XCTAssertEqual(onionPowder.groupFeatureIDs, ["group:en:onion-family-vegetable"])

        let tomato = DigestionCatalog.rollUp(leafID: "en:tomato", taxonomy: taxonomy)
        XCTAssertEqual(tomato.ingredientFeatureIDs, ["ingredient:en:tomato"])
        XCTAssertEqual(tomato.groupFeatureIDs, ["group:en:fruit-vegetable"])

        let wheatFlour = DigestionCatalog.rollUp(leafID: "en:wheat-flour", taxonomy: taxonomy)
        XCTAssertEqual(wheatFlour.ingredientFeatureIDs, ["ingredient:en:wheat"])
        XCTAssertEqual(wheatFlour.groupFeatureIDs, ["group:en:cereal"])
    }

    func testLeafWithoutBaseStaysItself() {
        let rolled = DigestionCatalog.rollUp(leafID: "en:e420", taxonomy: taxonomy)
        XCTAssertEqual(rolled.ingredientFeatureIDs, ["ingredient:en:e420"])
        XCTAssertEqual(rolled.groupFeatureIDs, [])
    }

    func testEveryCatalogIDExistsInTaxonomy() {
        XCTAssertLessThanOrEqual(DigestionCatalog.bases.count, 80)
        XCTAssertLessThanOrEqual(DigestionCatalog.groups.count, 25)
        XCTAssertEqual(Set(DigestionCatalog.bases).count, DigestionCatalog.bases.count)
        XCTAssertEqual(Set(DigestionCatalog.groups).count, DigestionCatalog.groups.count)
        for id in DigestionCatalog.bases + DigestionCatalog.groups {
            XCTAssertTrue(taxonomy.contains(id), "\(id) missing from bundled taxonomy")
        }
    }
}
