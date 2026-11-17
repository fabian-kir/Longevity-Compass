import Foundation

struct OpenFoodFactsProduct {
    let barcode: String
    let name: String?
    let brand: String?
    let imageURL: URL?
    let servingSizeGrams: Double?
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
    static func search(query: String) async throws -> [OpenFoodFactsProduct] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://world.openfoodfacts.org/cgi/search.pl?search_terms=\(encoded)&search_simple=1&action=process&json=1&page_size=25") else {
            throw OpenFoodFactsError.malformedResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("LongevityDirection/0.2 (personal)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenFoodFactsError.network("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw OpenFoodFactsError.network("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = json["products"] as? [[String: Any]] else {
            throw OpenFoodFactsError.malformedResponse
        }
        return products.compactMap { dict in
            guard let code = dict["code"] as? String, !code.isEmpty else { return nil }
            let product = parse(product: dict, barcode: code)
            guard product.name != nil else { return nil }
            return product
        }
    }

    static func lookup(barcode: String) async throws -> OpenFoodFactsProduct {
        let normalized = barcode.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { throw OpenFoodFactsError.notFound }
        let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(normalized).json")!
        var request = URLRequest(url: url)
        request.setValue("LongevityDirection/0.2 (personal)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenFoodFactsError.network("No HTTP response")
        }
        if http.statusCode == 404 { throw OpenFoodFactsError.notFound }
        guard (200...299).contains(http.statusCode) else {
            throw OpenFoodFactsError.network("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenFoodFactsError.malformedResponse
        }
        let status = (json["status"] as? Int) ?? 0
        guard status == 1, let product = json["product"] as? [String: Any] else {
            throw OpenFoodFactsError.notFound
        }
        return parse(product: product, barcode: normalized)
    }

    private static func parse(product: [String: Any], barcode: String) -> OpenFoodFactsProduct {
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        func d(_ key: String) -> Double? {
            if let v = nutriments[key] as? Double { return v }
            if let v = nutriments[key] as? Int    { return Double(v) }
            if let s = nutriments[key] as? String { return Double(s) }
            return nil
        }
        let imageString = product["image_front_url"] as? String ?? product["image_url"] as? String
        let servingSizeStr = product["serving_size"] as? String
        let servingGrams: Double? = {
            guard let s = servingSizeStr else { return nil }
            let digits = s.split(separator: " ").first.map(String.init) ?? s
            let cleaned = digits.replacingOccurrences(of: "g", with: "")
                                .replacingOccurrences(of: ",", with: ".")
                                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        }()
        return OpenFoodFactsProduct(
            barcode: barcode,
            name: product["product_name"] as? String,
            brand: (product["brands"] as? String)?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces),
            imageURL: imageString.flatMap { URL(string: $0) },
            servingSizeGrams: servingGrams,
            novaGroup: (product["nova_group"] as? Int) ?? Int((product["nova_group"] as? String) ?? ""),
            kcal100g:    d("energy-kcal_100g") ?? d("energy_kcal_100g"),
            protein100g: d("proteins_100g"),
            fiber100g:   d("fiber_100g"),
            carbs100g:   d("carbohydrates_100g"),
            fat100g:     d("fat_100g"),
            satFat100g:  d("saturated-fat_100g"),
            sugars100g:  d("sugars_100g"),
            salt100g:    d("salt_100g"),
            sodium100g:  d("sodium_100g")
        )
    }
}
