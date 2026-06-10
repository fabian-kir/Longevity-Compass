import Foundation

struct MealAnalysisResult: Decodable {
    let productName: String?
    let portionGrams: Double?
    let proteinGrams: Double?
    let fiberGrams: Double?
    let carbsGrams: Double?
    let fatGrams: Double?
    let saturatedFatGrams: Double?
    let addedSugarGrams: Double?
    let sodiumMilligrams: Double?
    let isFattyFish: Bool?
    let leafyGreenServings: Double?
    let ultraProcessedScore: Double?
    let aiNotes: String?
    let confidence: String?
}

struct CompletedAnalysis {
    let result: MealAnalysisResult
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

    // MARK: - Analysis

    func analyzeMeal(imageJPEG: Data?, freeText: String) async throws -> CompletedAnalysis {
        guard let key = Keychain.get(.openRouterAPIKey), !key.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }

        var content: [[String: Any]] = [
            ["type": "text", "text": userPrompt(freeText: freeText, hasImage: imageJPEG != nil)]
        ]
        if let jpeg = imageJPEG {
            let b64 = jpeg.base64EncodedString()
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(b64)"],
            ])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": content],
            ],
            "response_format": ["type": "json_object"],
            "max_tokens": 800,
            "temperature": 0.2,
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

        let parsed = try parseAnalysis(contentString)
        let cost = computeCost(inputTokens: inputTokens, outputTokens: outputTokens)
        return CompletedAnalysis(
            result: parsed,
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

    private func parseAnalysis(_ raw: String) throws -> MealAnalysisResult {
        // Some models wrap JSON in markdown fences despite response_format. Strip them.
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else {
            throw OpenRouterError.malformedResponse("UTF-8 encoding")
        }
        do {
            return try JSONDecoder().decode(MealAnalysisResult.self, from: data)
        } catch {
            throw OpenRouterError.malformedResponse("JSON decode: \(error.localizedDescription)\nRaw: \(cleaned.prefix(400))")
        }
    }

    // MARK: - Prompts

    private var systemPrompt: String {
        """
        You are a nutrition estimator for a personal health app. Your job is to take a free-form description of a meal (and optionally a photo) and return a coarse, directional nutrient estimate in JSON.

        Rules:
        - Be honest about uncertainty. Do not pretend gram-precision you don't have.
        - Always estimate a sensible total portion size in grams.
        - Output one consolidated estimate for the whole meal described.
        - If the input is ambiguous, pick the most likely common interpretation and mention what you assumed in `aiNotes`.
        - Do not give medical advice. Do not moralise. Do not include text outside the JSON.
        - Reply with a JSON object only. No prose, no markdown fences.

        Schema (all numeric fields in the units shown; null when unknown):
        {
          "productName": string|null,
          "portionGrams": number|null,
          "proteinGrams": number|null,
          "fiberGrams": number|null,
          "carbsGrams": number|null,
          "fatGrams": number|null,
          "saturatedFatGrams": number|null,
          "addedSugarGrams": number|null,
          "sodiumMilligrams": number|null,
          "isFattyFish": boolean|null,
          "leafyGreenServings": number|null,
          "ultraProcessedScore": number|null,
          "aiNotes": string|null,
          "confidence": "low"|"medium"|"high"
        }

        Definitions:
        - "isFattyFish" = true only when the meal contains a clear serving of oily fish (salmon, sardines, herring, trout, mackerel, anchovy, mussels).
        - "leafyGreenServings" counts cups of raw or ½ cup cooked greens (spinach, kale, lettuce, rocket, chard).
        - "ultraProcessedScore": 0.0 means entirely whole foods, 1.0 means entirely ultra-processed (packaged snacks, sodas, fast food). Use a single number between 0 and 1 for the meal as a whole.
        - "addedSugarGrams" should EXCLUDE naturally occurring sugars in whole fruit, dairy, etc. Estimate added/refined sugars only.
        - "confidence" reflects your own certainty about the estimate, not the meal's healthiness.
        """
    }

    private func userPrompt(freeText: String, hasImage: Bool) -> String {
        var s = "Analyze this meal and return the JSON object as specified.\n"
        if !freeText.isEmpty {
            s += "\nUser's description: \(freeText)\n"
        }
        if hasImage {
            s += "\nA photo of the meal is attached. Use it as the primary source; the description (if any) is supplementary."
        }
        return s
    }
}
