import Foundation

struct MealFingerprintAnalysis {
    let fingerprint: MealFingerprint
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

enum OpenRouterError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case malformedResponse(String)
    case noContent

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenRouter API key not set. Add it in the Data tab."
        case .http(let code, let body):
            return "OpenRouter \(code): \(body)"
        case .malformedResponse(let m):
            return "Malformed response: \(m)"
        case .noContent:
            return "Model returned an empty response."
        }
    }
}

@Observable
final class OpenRouterClient {
    var lastError: String?

    var hasAPIKey: Bool { Keychain.get(.openRouterAPIKey)?.isEmpty == false }
    var model: String {
        Keychain.get(.openRouterModel) ?? HealthThresholds.OpenRouter.defaultModel
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(.openRouterAPIKey)
        } else {
            Keychain.set(trimmed, for: .openRouterAPIKey)
        }
    }

    func setModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(.openRouterModel)
        } else {
            Keychain.set(trimmed, for: .openRouterModel)
        }
    }

    // MARK: - Fingerprint analysis (vision)

    func analyzeMealFingerprint(imageJPEG: Data) async throws -> MealFingerprintAnalysis {
        guard let key = Keychain.get(.openRouterAPIKey), !key.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }

        let b64 = imageJPEG.base64EncodedString()
        let content: [[String: Any]] = [
            ["type": "text", "text": userPrompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]],
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": content],
            ],
            "response_format": ["type": "json_object"],
            "max_tokens": 500,
            "temperature": 0.1,
        ]

        var request = URLRequest(url: HealthThresholds.OpenRouter.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)",                                    forHTTPHeaderField: "Authorization")
        request.setValue("application/json",                                  forHTTPHeaderField: "Content-Type")
        request.setValue(HealthThresholds.OpenRouter.httpReferer,             forHTTPHeaderField: "HTTP-Referer")
        request.setValue(HealthThresholds.OpenRouter.appTitle,                forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.malformedResponse("No HTTPURLResponse")
        }
        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.http(http.statusCode, bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenRouterError.malformedResponse("Top-level JSON")
        }
        let usedModel = (json["model"] as? String) ?? model
        let usage = json["usage"] as? [String: Any] ?? [:]
        let inputTokens  = (usage["prompt_tokens"]     as? Int) ?? 0
        let outputTokens = (usage["completion_tokens"] as? Int) ?? 0

        guard
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw OpenRouterError.malformedResponse("choices/message")
        }

        let contentString: String = {
            if let s = message["content"] as? String { return s }
            if let arr = message["content"] as? [[String: Any]] {
                return arr.compactMap { $0["text"] as? String }.joined()
            }
            return ""
        }()

        guard !contentString.isEmpty else { throw OpenRouterError.noContent }

        let parsed = try parseFingerprint(contentString)
        let cost = computeCost(inputTokens: inputTokens, outputTokens: outputTokens)
        return MealFingerprintAnalysis(
            fingerprint: parsed,
            model: usedModel,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: cost
        )
    }

    // MARK: - Cost

    func computeCost(inputTokens: Int, outputTokens: Int) -> Double {
        let input  = Double(inputTokens)  * HealthThresholds.OpenRouter.inputUSDPerMillion  / 1_000_000.0
        let output = Double(outputTokens) * HealthThresholds.OpenRouter.outputUSDPerMillion / 1_000_000.0
        return input + output
    }

    // MARK: - Parsing

    private func parseFingerprint(_ raw: String) throws -> MealFingerprint {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else {
            throw OpenRouterError.malformedResponse("UTF-8 encoding")
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(MealFingerprint.self, from: data)
        } catch {
            throw OpenRouterError.malformedResponse("JSON decode: \(error.localizedDescription)\nRaw: \(cleaned.prefix(400))")
        }
    }

    // MARK: - Prompts

    private var systemPrompt: String {
        """
        You are a meal photo classifier for a longevity app. Given a photo, return a JSON object describing the meal in terms of food categories and plant ingredients. You do NOT estimate grams, calories, or macros.

        Schema (return only this JSON object, no markdown, no prose):
        {
          "title": <string>,
          "items": [ { "category": <category>, "plateFraction": <0.0..1.0> }, ... ],
          "plantIngredients": [ <string>, ... ],
          "aiNotes": <string|null>,
          "confidence": "low"|"medium"|"high"
        }

        Allowed category values (use exactly these strings):
        - leafyGreens     — spinach, kale, lettuce, arugula, chard, etc.
        - cruciferous     — broccoli, cauliflower, cabbage, brussels sprouts
        - otherVeg        — peppers, tomato, carrot, mushrooms, zucchini, onion, etc.
        - fruit           — any whole fruit, fresh or dried
        - legumes         — beans, lentils, chickpeas, peas, tofu, edamame
        - wholeGrains     — oats, brown rice, quinoa, whole wheat, barley
        - refinedCarbs    — white bread, white rice, regular pasta, croissants, pastries
        - nutsAndSeeds    — almonds, walnuts, flax, chia, sesame, etc.
        - omega3Source    — oily fish (salmon, sardines, mackerel, herring, trout), or substantial walnuts/flax/chia/algae
        - leanProtein     — chicken, eggs, white fish, tofu, low-fat dairy protein
        - redMeat         — beef, pork, lamb (unprocessed)
        - processedMeat   — sausage, bacon, ham, salami, hot dog, deli meats
        - dairyOrAlt      — milk, cheese, plain yogurt, plant milks (excluding fermented)
        - fermented       — yogurt with live cultures, kefir, kimchi, sauerkraut, miso, kombucha
        - ultraProcessed  — packaged snacks, chips, fast food, instant noodles, soda, candy
        - fried           — deep-fried foods regardless of base
        - sugaryDrinks    — sodas, fruit juice, sweetened drinks

        Rules:
        - title is a short human-readable meal name (2–6 words), e.g. "Grilled salmon with rice & broccoli" or "Chicken caesar salad". No emojis, no trailing punctuation.
        - A single food may belong to multiple categories (e.g., fried chicken → leanProtein AND fried; salmon → leanProtein AND omega3Source).
        - plateFraction is the visual fraction of the plate this category occupies. The sum across all items should be ≤ 1.0; small overlaps are fine.
        - plantIngredients is a short list of distinct *plant* ingredient names visible in the meal (e.g. ["kale","tomato","lentils","walnuts"]). Use simple lowercase singular names. Do not include animal products. Empty list is fine.
        - If the photo is ambiguous, pick the most likely interpretation and put your assumption in aiNotes.
        - Do not output anything other than the JSON object.
        """
    }

    private var userPrompt: String {
        "Classify this meal and return the JSON object as specified."
    }
}
