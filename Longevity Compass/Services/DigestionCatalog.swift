import Foundation

// Features Digestion Insights rolls ingredients up to.
//
// Selection rule: a taxonomy ID is listed for food identity and commonness
// only: foods people eat often, and the families they belong to. Never because
// a food is suspected to upset digestion. Variants roll up to the base they
// descend from (onion powder → onion); a leaf with no base above it stays its
// own feature. Every ID must exist in the bundled taxonomy
// (`IngredientTaxonomyTests`).
//
// Reviewed by user: pending (unit 6)

nonisolated enum DigestionCatalog {
    /// Common foods, at most 80.
    static let bases: [String] = [
        // Grains and starches
        "en:wheat", "en:rye", "en:barley", "en:oat", "en:rice", "en:corn",
        "en:potato", "en:sweet-potato", "en:bread", "en:pasta",
        // Vegetables and pulses
        "en:onion", "en:garlic", "en:leek", "en:tomato", "en:bell-pepper", "en:chili-pepper",
        "en:cucumber", "en:carrot", "en:celery", "en:mushroom", "en:cabbage", "en:broccoli",
        "en:cauliflower", "en:spinach", "en:lettuce", "en:courgette", "en:aubergine",
        "en:pea", "en:green-bean", "en:chickpea", "en:lentils", "en:beans", "en:soya-bean",
        // Fruit
        "en:apple", "en:pear", "en:banana", "en:orange", "en:lemon", "en:grape",
        "en:strawberry", "en:peach", "en:plum", "en:cherry", "en:mango", "en:pineapple",
        "en:avocado",
        // Dairy and eggs
        "en:milk", "en:cream", "en:butter", "en:yogurt", "en:egg",
        // Meat and fish
        "en:beef", "en:pork", "en:chicken", "en:turkey", "en:lamb",
        "en:salmon", "en:tuna", "en:shrimp",
        // Nuts and seeds
        "en:peanut", "en:almond", "en:hazelnut", "en:walnut", "en:cashew-nuts",
        "en:sesame", "en:sunflower-seed",
        // Drinks, sweet things
        "en:coffee", "en:tea", "en:cocoa", "en:chocolate", "en:sugar", "en:honey",
        "en:wine", "en:beer",
        // Fats and condiments
        "en:olive-oil", "en:palm-oil", "en:mustard", "en:soy-sauce", "en:vinegar",
    ]

    /// Food families, at most 25.
    static let groups: [String] = [
        "en:onion-family-vegetable", "en:brassica", "en:legume", "en:leaf-vegetable",
        "en:fruit-vegetable",
        "en:citrus-fruit", "en:berries", "en:prunus-species-fruit",
        "en:cereal", "en:dairy", "en:cheese",
        "en:meat", "en:poultry", "en:fish", "en:shellfish", "en:crustacean",
        "en:nut", "en:tree-nut", "en:seed",
        "en:vegetable-oil-and-fat", "en:added-sugar", "en:spice", "en:alcohol",
    ]

    private static let baseSet = Set(bases)
    private static let groupSet = Set(groups)

    struct RolledUp: Equatable, Sendable {
        /// `ingredient:<taxonomy ID>` feature IDs, sorted.
        let ingredientFeatureIDs: [String]
        /// `group:<taxonomy ID>` feature IDs, sorted.
        let groupFeatureIDs: [String]
    }

    /// Closure of leaf L = {L} plus its ancestors. Ingredient features = catalog
    /// bases in the closure, or L itself when there are none. Group features =
    /// catalog groups in the closure.
    static func rollUp(leafID: String, taxonomy: IngredientTaxonomy) -> RolledUp {
        let closure = taxonomy.ancestors(of: leafID).union([leafID])
        let baseHits = closure.intersection(baseSet)
        let ingredients = baseHits.isEmpty ? [leafID] : baseHits.sorted()
        return RolledUp(
            ingredientFeatureIDs: ingredients.map { "ingredient:\($0)" },
            groupFeatureIDs: closure.intersection(groupSet).sorted().map { "group:\($0)" }
        )
    }
}
