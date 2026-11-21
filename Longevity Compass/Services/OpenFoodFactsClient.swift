import Foundation

struct OpenFoodFactsProduct {
    let barcode: String
    let name: String?
    let brand: String?
    let imageURL: URL?
    /// One labelled serving, in grams (or millilitres for drinks; Open Food
    /// Facts reports drink nutrients per 100 ml, so the scaling is the same).
    let servingSizeGrams: Double?
    let servingUnit: String
    /// Free-text serving label, e.g. "1 biscuit (10 g)".
    let servingLabel: String?
    /// Net content of the whole pack, in the same unit as the serving.
    let packageGrams: Double?
    let novaGroup: Int?               // 1 (whole) … 4 (ultra-processed)
    // Per-100g nutrients
    let kcal100g: Double?
    let protein100g: Double?
    let fiber100g: Double?
    let carbs100g: Double?
    let fat100g: Double?
    let satFat100g: Double?
    let sugars100g: Double?
    let salt100g: Double?
    let sodium100g: Double?
    /// Allergens, traces, free-from labels and ingredients. Nil for search
    /// results and for products without any of these fields.
    var ingredientProfile: IngredientProfile? = nil

    var ultraProcessedScore: Double? {
        guard let n = novaGroup else { return nil }
        // 1 → 0.0, 2 → 0.33, 3 → 0.67, 4 → 1.0
        return Double(max(1, min(4, n)) - 1) / 3.0
    }

    func scaled(toGrams grams: Double) -> ScaledNutrients {
        let f = grams / 100.0
        return ScaledNutrients(
            portionGrams: grams,
            kcalTotal: kcal100g.map { $0 * f },
            protein: protein100g.map { $0 * f },
            fiber: fiber100g.map { $0 * f },
            carbs: carbs100g.map { $0 * f },
            fat: fat100g.map { $0 * f },
            saturatedFat: satFat100g.map { $0 * f },
            addedSugar: sugars100g.map { $0 * f },  // OFF reports total sugars; treat as proxy
            sodiumMg: {
                if let mg = sodium100g { return mg * 1000 * f }    // OFF "sodium_100g" is in g
                if let salt = salt100g { return salt * 0.4 * 1000 * f }  // salt → sodium ≈ × 0.4
                return nil
            }()
        )
    }
}

struct ScaledNutrients {
    let portionGrams: Double?
    let kcalTotal: Double?
    let protein: Double?
    let fiber: Double?
    let carbs: Double?
    let fat: Double?
    let saturatedFat: Double?
    let addedSugar: Double?
    let sodiumMg: Double?
}

enum OpenFoodFactsError: LocalizedError {
    case notFound
    case malformedResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notFound:           "Product not found in Open Food Facts."
        case .malformedResponse:  "Unexpected response from Open Food Facts."
        case .network(let m):     "Network error: \(m)"
        }
    }
}

enum OpenFoodFactsClient {
    /// Open Food Facts asks API clients to identify themselves with app name,
    /// version and a contact point.
    private static let userAgent = "LongevityDirection/0.2 (https://github.com/fabian-kir/Longevity-Direction)"

    private static let searchFields = [
        "code", "product_name", "brands", "image_front_url", "image_url",
        "serving_size", "serving_quantity", "serving_quantity_unit",
        "product_quantity", "product_quantity_unit", "quantity", "nova_group", "nutriments",
    ].joined(separator: ",")

    /// The search service does not return `ingredients`, `traces_tags` or
    /// `unknown_ingredients_n` (checked 2026-11-20), so only the product API
    /// asks for the ingredient profile fields.
    private static let productFields = searchFields + "," + [
        "allergens_tags", "traces_tags", "labels_tags", "ingredients", "ingredients_n",
        "unknown_ingredients_n", "states_tags",
    ].joined(separator: ",")

    struct Quantity: Equatable {
        let value: Double
        let unit: String   // "g" or "ml"
    }

    /// Reads an amount as grams or millilitres. Prefers the numeric field and
    /// falls back to the last "<number> <unit>" in the free-text label, so
    /// "1 biscuit (10 g)" yields 10 g rather than the leading count.
    static func quantity(amount: Any?, unit: Any?, label: String?) -> Quantity? {
        let numeric: Double? = {
            if let v = amount as? Double { return v }
            if let v = amount as? Int { return Double(v) }
            if let s = amount as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
            return nil
        }()
        if let numeric, numeric > 0,
           let q = normalized(numeric, unit: (unit as? String) ?? "g") {
            return q
        }

        guard let label else { return nil }
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(kg|g|ml|cl|l)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(label.startIndex..., in: label)
        guard let match = regex.matches(in: label, range: range).last,
              let numberRange = Range(match.range(at: 1), in: label),
              let unitRange = Range(match.range(at: 2), in: label),
              let value = Double(label[numberRange].replacingOccurrences(of: ",", with: ".")),
              value > 0
        else { return nil }
        return normalized(value, unit: String(label[unitRange]))
    }

    private static func normalized(_ value: Double, unit: String) -> Quantity? {
        switch unit.lowercased() {
        case "g":  Quantity(value: value, unit: "g")
        case "kg": Quantity(value: value * 1000, unit: "g")
        case "ml": Quantity(value: value, unit: "ml")
        case "cl": Quantity(value: value * 10, unit: "ml")
        case "l":  Quantity(value: value * 1000, unit: "ml")
        default:   nil
        }
    }

    static func search(query: String) async throws -> [OpenFoodFactsProduct] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        // Search-a-licious replaces the legacy cgi/search.pl endpoint, which is
        // heavily rate limited and answers roughly half of requests with HTTP 503.
        var components = URLComponents(string: "https://search.openfoodfacts.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "page_size", value: "25"),
            URLQueryItem(name: "fields", value: searchFields),
        ]
        guard let url = components.url else {
            throw OpenFoodFactsError.malformedResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenFoodFactsError.network("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw OpenFoodFactsError.network("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = json["hits"] as? [[String: Any]] else {
            throw OpenFoodFactsError.malformedResponse
        }
        return products.compactMap { dict in
            guard let code = dict["code"] as? String, !code.isEmpty else { return nil }
            let product = parse(product: dict, barcode: code)
            guard product.name != nil else { return nil }
            return product
        }
    }

    /// Looks a barcode up on the product API, then falls back to the search
    /// service. The product API rate limits aggressively (HTTP 429/503 after a
    /// handful of requests), while search runs on separate infrastructure.
    static func lookup(barcode: String) async throws -> OpenFoodFactsProduct {
        let normalized = barcode.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { throw OpenFoodFactsError.notFound }
        do {
            return try await productAPILookup(barcode: normalized)
        } catch OpenFoodFactsError.notFound {
            throw OpenFoodFactsError.notFound
        } catch {
            if let product = try await searchLookup(barcode: normalized) {
                return product
            }
            throw error
        }
    }

    private static func productAPILookup(barcode: String) async throws -> OpenFoodFactsProduct {
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json")!
        components.queryItems = [URLQueryItem(name: "fields", value: productFields)]
        guard let url = components.url else { throw OpenFoodFactsError.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenFoodFactsError.network("No HTTP response")
        }
        if http.statusCode == 404 { throw OpenFoodFactsError.notFound }
        guard (200...299).contains(http.statusCode) else {
            throw OpenFoodFactsError.network("HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenFoodFactsError.malformedResponse
        }
        let status = (json["status"] as? Int) ?? 0
        guard status == 1, let product = json["product"] as? [String: Any] else {
            throw OpenFoodFactsError.notFound
        }
        return parse(product: product, barcode: barcode, includesProfile: true)
    }

    /// Returns nil when the search service is unreachable or has no match, so the
    /// caller can surface the original product API error instead.
    private static func searchLookup(barcode: String) async throws -> OpenFoodFactsProduct? {
        var components = URLComponents(string: "https://search.openfoodfacts.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "code:\(barcode)"),
            URLQueryItem(name: "page_size", value: "1"),
            URLQueryItem(name: "fields", value: searchFields),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hit = (json["hits"] as? [[String: Any]])?.first(where: { ($0["code"] as? String) == barcode })
        else { return nil }
        return parse(product: hit, barcode: barcode)
    }

    /// `includesProfile` is false for search service results, which lack the
    /// fields a complete profile needs.
    static func parse(
        product: [String: Any],
        barcode: String,
        includesProfile: Bool = false,
        taxonomy: IngredientTaxonomy = .shared
    ) -> OpenFoodFactsProduct {
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        func d(_ key: String) -> Double? {
            if let v = nutriments[key] as? Double { return v }
            if let v = nutriments[key] as? Int    { return Double(v) }
            if let s = nutriments[key] as? String { return Double(s) }
            return nil
        }
        let imageString = product["image_front_url"] as? String ?? product["image_url"] as? String
        let servingLabel = (product["serving_size"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let serving = quantity(
            amount: product["serving_quantity"],
            unit: product["serving_quantity_unit"],
            label: servingLabel
        )
        let package = quantity(
            amount: product["product_quantity"],
            unit: product["product_quantity_unit"],
            label: product["quantity"] as? String
        )
        return OpenFoodFactsProduct(
            barcode: barcode,
            name: product["product_name"] as? String,
            // The product API returns brands as a comma-separated string; search returns an array.
            brand: ((product["brands"] as? [String])?.first
                    ?? (product["brands"] as? String)?.components(separatedBy: ",").first)?
                .trimmingCharacters(in: .whitespaces),
            imageURL: imageString.flatMap { URL(string: $0) },
            servingSizeGrams: serving?.value,
            servingUnit: serving?.unit ?? package?.unit ?? "g",
            servingLabel: servingLabel.flatMap { $0.isEmpty ? nil : $0 },
            // A pack measured in another unit than the serving cannot be combined with it.
            packageGrams: package.flatMap { serving == nil || $0.unit == serving?.unit ? $0.value : nil },
            novaGroup: (product["nova_group"] as? Int) ?? Int((product["nova_group"] as? String) ?? ""),
            kcal100g:    d("energy-kcal_100g") ?? d("energy_kcal_100g"),
            protein100g: d("proteins_100g"),
            fiber100g:   d("fiber_100g"),
            carbs100g:   d("carbohydrates_100g"),
            fat100g:     d("fat_100g"),
            satFat100g:  d("saturated-fat_100g"),
            sugars100g:  d("sugars_100g"),
            salt100g:    d("salt_100g"),
            sodium100g:  d("sodium_100g"),
            ingredientProfile: includesProfile
                ? ingredientProfile(product: product, alcohol100g: d("alcohol_100g"), taxonomy: taxonomy)
                : nil
        )
    }

    // MARK: - Ingredient profile

    private static let profileFields = ["allergens_tags", "traces_tags", "labels_tags", "ingredients"]

    /// Builds the profile from Open Food Facts' own fields only; no scoring of our own.
    static func ingredientProfile(
        product: [String: Any],
        alcohol100g: Double?,
        taxonomy: IngredientTaxonomy
    ) -> IngredientProfile? {
        guard profileFields.contains(where: { product[$0] != nil }) else { return nil }

        let labelTags = strings(product["labels_tags"])
        var freeFrom: [FreeFromMark] = []
        for tag in labelTags {
            guard let label = taxonomy.freeFromLabel(forLabelTag: tag),
                  !freeFrom.contains(where: { $0.label == label }) else { continue }
            freeFrom.append(FreeFromMark(label: label, source: .declared))
        }

        var ingredientIDs: [String] = []
        collectIngredientIDs(product["ingredients"], taxonomy: taxonomy, into: &ingredientIDs)

        let containsAlcohol: Bool? = {
            if labelTags.contains("en:contains-alcohol") { return true }
            return alcohol100g.map { $0 > 0.5 }
        }()
        let unknownCount = int(product["unknown_ingredients_n"])
        let complete: Bool? = product["states_tags"] == nil ? nil
            : strings(product["states_tags"]).contains("en:ingredients-completed") && unknownCount == 0

        return IngredientProfile(
            origin: .openFoodFacts,
            allergens: EUAllergen.parse(strings(product["allergens_tags"]))
                .map { AllergenMark(allergen: $0, source: .declared) },
            traces: EUAllergen.parse(strings(product["traces_tags"])),
            ingredientIDs: ingredientIDs,
            unmatchedIngredientNames: [],
            freeFrom: freeFrom,
            containsAlcohol: containsAlcohol,
            offIngredientsComplete: complete,
            offIngredientsCount: int(product["ingredients_n"]),
            offUnknownIngredientsCount: unknownCount
        )
    }

    /// Walks nested ingredients depth first, keeping IDs the bundled taxonomy
    /// knows, in listed order, without duplicates.
    private static func collectIngredientIDs(_ value: Any?, taxonomy: IngredientTaxonomy, into ids: inout [String]) {
        for item in value as? [[String: Any]] ?? [] {
            let inOFFTaxonomy = int(item["is_in_taxonomy"]).map { $0 != 0 } ?? true
            if let id = item["id"] as? String, inOFFTaxonomy, taxonomy.contains(id), !ids.contains(id) {
                ids.append(id)
            }
            collectIngredientIDs(item["ingredients"], taxonomy: taxonomy, into: &ids)
        }
    }

    private static func strings(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private static func int(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
