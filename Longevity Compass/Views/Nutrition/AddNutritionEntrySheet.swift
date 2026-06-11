import SwiftUI
import UIKit

/// Presented after a meal photo is captured. Runs the analysis pipeline,
/// shows the result, and saves the entry — or queues it if offline.
struct PostCaptureSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let capturedAt: Date
    let onFinish: (Outcome) -> Void

    enum Outcome {
        case saved(title: String)
        case queued
        case cancelled
        case failed(String)
    }

    private enum Phase {
        case analyzing
        case barcode(OpenFoodFactsProduct)
        case aiFingerprint(MealFingerprintAnalysis)
        case offline(String)
        case failed(String)
    }

    @State private var phase: Phase = .analyzing
    @State private var portionGrams: Double?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onFinish(.cancelled)
                            dismiss()
                        }
                    }
                }
        }
        .task { await analyze() }
    }

    private var title: String {
        switch phase {
        case .analyzing:        "Analysing meal…"
        case .barcode:          "Confirm portion"
        case .aiFingerprint:    "Confirm meal"
        case .offline:          "Saved for later"
        case .failed:           "Could not analyse"
        }
    }

    // MARK: - Content per phase

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .analyzing:
            analyzingView
        case .barcode(let product):
            barcodeConfirm(product: product)
        case .aiFingerprint(let analysis):
            fingerprintConfirm(analysis: analysis)
        case .offline(let message):
            offlineView(message: message)
        case .failed(let message):
            failedView(message: message)
        }
    }

    private var analyzingView: some View {
        VStack(spacing: 16) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            ProgressView()
            Text("Checking for a barcode, then handing off to AI if needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .padding(.top, 12)
    }

    private func offlineView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            Button("Done") {
                onFinish(.queued)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom)
        }
        .padding(.top, 40)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("Retry") {
                    Task { await analyze() }
                }
                .buttonStyle(.bordered)
                Button("Save for later") {
                    services.pendingMeals.enqueue(image: image, capturedAt: capturedAt)
                    onFinish(.queued)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(.top, 40)
    }

    // MARK: - Barcode confirm

    private func barcodeConfirm(product: OpenFoodFactsProduct) -> some View {
        Form {
            Section("Product") {
                HStack(alignment: .top) {
                    if let url = product.imageURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFit()
                            default: Color(.secondarySystemBackground)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(product.name ?? "Unknown product").font(.headline).lineLimit(2)
                        if let brand = product.brand { Text(brand).font(.caption).foregroundStyle(.secondary) }
                        Text(product.barcode).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Section("Portion") {
                HStack {
                    Text("Grams eaten")
                    Spacer()
                    TextField(
                        product.servingSizeGrams.map { "\(Int($0))" } ?? "100",
                        value: $portionGrams,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                }
                if let s = product.servingSizeGrams {
                    Text("Package serving: \(Int(s)) g").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Per-100 g (Open Food Facts)") {
                if let v = product.protein100g { row("Protein", String(format: "%.1f g", v)) }
                if let v = product.fiber100g   { row("Fibre",   String(format: "%.1f g", v)) }
                if let v = product.carbs100g   { row("Carbs",   String(format: "%.1f g", v)) }
                if let v = product.fat100g     { row("Fat",     String(format: "%.1f g", v)) }
                if let v = product.satFat100g  { row("Saturated fat", String(format: "%.1f g", v)) }
                if let v = product.sugars100g  { row("Sugars",  String(format: "%.1f g", v)) }
                if let v = product.salt100g    { row("Salt",    String(format: "%.2f g", v)) }
                if let n = product.novaGroup   { row("NOVA group", "\(n) / 4") }
            }

            Section {
                Button {
                    saveBarcode(product: product)
                } label: {
                    Label("Save entry", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
    }

    private func fingerprintConfirm(analysis: MealFingerprintAnalysis) -> some View {
        let fp = analysis.fingerprint
        let sortedItems = fp.items.sorted { $0.plateFraction > $1.plateFraction }
        return Form {
            Section {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            if let title = fp.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                Section("Meal") {
                    Text(title).font(.headline)
                }
            }
            Section("Categories on plate") {
                if sortedItems.isEmpty {
                    Text("No categories detected.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(sortedItems, id: \.category) { item in
                        HStack {
                            Image(systemName: item.category.systemImage)
                                .frame(width: 22)
                                .foregroundStyle(item.category.isAvoid ? .orange : .secondary)
                            Text(item.category.displayLabel)
                            Spacer()
                            Text("\(Int(round(item.plateFraction * 100)))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            if !fp.plantIngredients.isEmpty {
                Section("Plant ingredients (\(fp.plantIngredients.count))") {
                    Text(fp.plantIngredients.joined(separator: ", "))
                        .font(.subheadline)
                }
            }
            if let notes = fp.aiNotes, !notes.isEmpty {
                Section("AI notes") { Text(notes).font(.footnote) }
            }
            Section {
                Button {
                    saveFingerprint(analysis: analysis)
                } label: {
                    Label("Save entry", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "—").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: - Pipeline

    private func analyze() async {
        phase = .analyzing
        do {
            let outcome = try await MealAnalysisPipeline.analyze(image: image, openRouter: services.openRouter)
            switch outcome {
            case .barcode(let product):
                phase = .barcode(product)
                portionGrams = product.servingSizeGrams
            case .aiFingerprint(let analysis):
                phase = .aiFingerprint(analysis)
            }
        } catch {
            if isNetworkRelated(error) {
                services.pendingMeals.enqueue(image: image, capturedAt: capturedAt)
                phase = .offline("No network — we’ll analyse this when you’re back online.")
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func isNetworkRelated(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        if let mae = error as? MealAnalysisError {
            switch mae {
            case .noNetwork: return true
            case .noUsableResult(let underlying):
                let u = underlying as NSError
                return u.domain == NSURLErrorDomain
            }
        }
        return false
    }

    // MARK: - Save

    private func saveBarcode(product: OpenFoodFactsProduct) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let portion = portionGrams ?? product.servingSizeGrams ?? 100
            let scaled  = product.scaled(toGrams: portion)
            let imageFileName = MealImageStore.save(image: image)
            let entry = NutritionEntry(
                date: capturedAt,
                source: .barcode,
                rawInput: product.barcode,
                productName: product.name,
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
            await services.recordNutritionEntry(entry)
            onFinish(.saved(title: product.name ?? "barcode"))
            dismiss()
        }
    }

    private func saveFingerprint(analysis: MealFingerprintAnalysis) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let imageFileName = MealImageStore.save(image: image)
            let entry = NutritionEntry.fromFingerprint(
                analysis,
                capturedAt: capturedAt,
                imageFileName: imageFileName
            )
            await services.recordNutritionEntry(entry)
            let aiTitle = analysis.fingerprint.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallback = analysis.fingerprint.plantIngredients.prefix(3).joined(separator: ", ")
            let title = !aiTitle.isEmpty ? aiTitle : (fallback.isEmpty ? "meal" : fallback)
            onFinish(.saved(title: title))
            dismiss()
        }
    }
}
