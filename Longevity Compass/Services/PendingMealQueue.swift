import Foundation
import Network
import UIKit

/// Disk-backed queue of meal photos awaiting analysis. Used when the user snaps a meal
/// while offline (or when the AI call fails transiently). Retries when connectivity returns.
@Observable
@MainActor
final class PendingMealQueue {

    struct PendingMeal: Codable, Identifiable {
        let id: UUID
        let imageFileName: String
        let capturedAt: Date
        var attempts: Int
    }

    private(set) var pending: [PendingMeal] = []
    private(set) var isOnline: Bool = true
    private(set) var isProcessing: Bool = false

    private let openRouter: OpenRouterClient
    private let onEntryReady: (NutritionEntry) async -> Void

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "meal.queue.monitor")
    private let fileManager = FileManager.default

    private static let maxAttempts = 5

    init(openRouter: OpenRouterClient, onEntryReady: @escaping (NutritionEntry) async -> Void) {
        self.openRouter = openRouter
        self.onEntryReady = onEntryReady
        loadManifest()
        startMonitor()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Enqueue

    func enqueue(image: UIImage, capturedAt: Date = .now) {
        guard let jpeg = image.jpegForAnalysis() else { return }
        let id = UUID()
        let fileName = "\(id.uuidString).jpg"
        let url = imageURL(for: fileName)
        do {
            try ensureDirectoryExists()
            try jpeg.write(to: url, options: .atomic)
        } catch {
            return
        }
        let meal = PendingMeal(id: id, imageFileName: fileName, capturedAt: capturedAt, attempts: 0)
        pending.append(meal)
        saveManifest()

        if isOnline {
            Task { await processQueue() }
        }
    }

    // MARK: - Process

    func processQueue() async {
        guard !isProcessing else { return }
        guard isOnline else { return }
        isProcessing = true
        defer { isProcessing = false }

        var index = 0
        while index < pending.count {
            var meal = pending[index]
            guard let image = UIImage(contentsOfFile: imageURL(for: meal.imageFileName).path) else {
                remove(meal)
                continue
            }
            meal.attempts += 1
            pending[index] = meal
            saveManifest()

            do {
                let outcome = try await MealAnalysisPipeline.analyze(image: image, openRouter: openRouter)
                let storedImage = MealImageStore.ingest(jpegAt: imageURL(for: meal.imageFileName))
                let entry = makeEntry(from: outcome, capturedAt: meal.capturedAt, imageFileName: storedImage)
                await onEntryReady(entry)
                remove(meal)
            } catch {
                if meal.attempts >= Self.maxAttempts {
                    remove(meal)
                } else {
                    // Stop processing this round; try again on next connectivity event.
                    index += 1
                    break
                }
            }
        }
    }

    // MARK: - Storage helpers

    private func directory() -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("PendingMeals", isDirectory: true)
    }

    private func ensureDirectoryExists() throws {
        let dir = directory()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func imageURL(for fileName: String) -> URL {
        directory().appendingPathComponent(fileName)
    }

    private func manifestURL() -> URL {
        directory().appendingPathComponent("manifest.json")
    }

    private func loadManifest() {
        do {
            try ensureDirectoryExists()
            let data = try Data(contentsOf: manifestURL())
            let decoded = try JSONDecoder().decode([PendingMeal].self, from: data)
            pending = decoded
        } catch {
            pending = []
        }
    }

    private func saveManifest() {
        do {
            try ensureDirectoryExists()
            let data = try JSONEncoder().encode(pending)
            try data.write(to: manifestURL(), options: .atomic)
        } catch {
            // Persistence failure is non-fatal — queue stays in memory.
        }
    }

    private func remove(_ meal: PendingMeal) {
        pending.removeAll { $0.id == meal.id }
        try? fileManager.removeItem(at: imageURL(for: meal.imageFileName))
        saveManifest()
    }

    // MARK: - Network monitor

    private func startMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                if online && wasOffline && !self.pending.isEmpty {
                    await self.processQueue()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - Outcome → entry

    private func makeEntry(
        from outcome: MealAnalysisOutcome,
        capturedAt: Date,
        imageFileName: String?
    ) -> NutritionEntry {
        switch outcome {
        case .barcode(let product):
            let portion = product.servingSizeGrams ?? 100
            let scaled = product.scaled(toGrams: portion)
            return NutritionEntry(
                date: capturedAt,
                source: .barcode,
                rawInput: product.barcode,
                productName: product.name,
                caloriesKcal: scaled.kcalTotal,
                portionGrams: scaled.portionGrams,
                proteinGrams: scaled.protein,
                fiberGrams: scaled.fiber,
                carbsGrams: scaled.carbs,
                fatGrams: scaled.fat,
                saturatedFatGrams: scaled.saturatedFat,
                addedSugarGrams: scaled.addedSugar,
                sodiumMilligrams: scaled.sodiumMg,
                isFattyFish: nil,
                leafyGreenServings: nil,
                ultraProcessedScore: product.ultraProcessedScore,
                aiNotes: nil,
                modelUsed: "openfoodfacts",
                inputTokens: nil,
                outputTokens: nil,
                costUSD: 0,
                imageFileName: imageFileName
            )
        case .aiFingerprint(let analysis):
            return NutritionEntry.fromFingerprint(analysis, capturedAt: capturedAt, imageFileName: imageFileName)
        }
    }
}

extension NutritionEntry {
    /// Builds a photo-source entry from an AI fingerprint analysis.
    /// Pass `portionGrams` to scale the per-100 g macro estimates into absolute values;
    /// nil leaves macro fields empty (used by the offline queue which has no user weight input).
    @MainActor static func fromFingerprint(
        _ analysis: MealFingerprintAnalysis,
        capturedAt: Date,
        portionGrams: Double? = nil,
        imageFileName: String? = nil
    ) -> NutritionEntry {
        let fp = analysis.fingerprint
        let json: String? = {
            guard let data = try? JSONEncoder().encode(fp) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        let title = fp.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scaled = portionGrams.flatMap { fp.scaledMacros(toGrams: $0) }
        return NutritionEntry(
            date: capturedAt,
            source: .photo,
            rawInput: "",
            productName: (title?.isEmpty == false) ? title : nil,
            caloriesKcal: scaled?.kcal,
            portionGrams: portionGrams,
            proteinGrams: scaled?.protein,
            fiberGrams: nil,
            carbsGrams: scaled?.carbs,
            fatGrams: scaled?.fat,
            saturatedFatGrams: nil,
            addedSugarGrams: nil,
            sodiumMilligrams: nil,
            isFattyFish: nil,
            leafyGreenServings: nil,
            ultraProcessedScore: nil,
            aiNotes: fp.aiNotes,
            modelUsed: analysis.model,
            inputTokens: analysis.inputTokens,
            outputTokens: analysis.outputTokens,
            costUSD: analysis.costUSD,
            fingerprintJSON: json,
            imageFileName: imageFileName
        )
    }
}
