import SwiftUI
import UIKit

struct AddNutritionEntrySheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    enum Screen {
        case picker
        case barcode
        case barcodeConfirm
        case camera
        case library
        case photoAnalysis
        case text
        case textAnalysis
    }

    @State private var screen: Screen = .picker
    @State private var scannedProduct: OpenFoodFactsProduct?
    @State private var pickedImage: UIImage?
    @State private var enteredText: String = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                switch screen {
                case .picker:
                    ModePicker(
                        canScanBarcode: BarcodeScannerView.isSupported,
                        hasAPIKey: services.openRouter.hasAPIKey,
                        onSelect: handleSelect
                    )
                case .barcode:
                    BarcodeStep(
                        onScanned: { product in
                            scannedProduct = product
                            screen = .barcodeConfirm
                        },
                        onError: { msg in error = msg; screen = .picker }
                    )
                case .barcodeConfirm:
                    if let product = scannedProduct {
                        BarcodeConfirmStep(product: product) { entry in save(entry) }
                    } else {
                        ProgressView()
                    }
                case .camera:
                    CapturePhotoStep(mode: .camera) { image in
                        if let image { pickedImage = image; screen = .photoAnalysis }
                        else { screen = .picker }
                    }
                case .library:
                    CapturePhotoStep(mode: .library) { image in
                        if let image { pickedImage = image; screen = .photoAnalysis }
                        else { screen = .picker }
                    }
                case .photoAnalysis:
                    if let img = pickedImage {
                        AnalyzeStep(text: "", image: img) { entry in save(entry) }
                    } else {
                        ProgressView()
                    }
                case .text:
                    TextStep(text: $enteredText) {
                        screen = .textAnalysis
                    }
                case .textAnalysis:
                    AnalyzeStep(text: enteredText, image: nil) { entry in save(entry) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if screen != .picker {
                        Button("Back") { screen = .picker }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Error", isPresented: .constant(error != nil), presenting: error) { _ in
                Button("OK", role: .cancel) { error = nil }
            } message: { msg in
                Text(msg)
            }
        }
    }

    private var title: String {
        switch screen {
        case .picker:           "Add nutrition entry"
        case .barcode:          "Scan barcode"
        case .barcodeConfirm:   "Confirm portion"
        case .camera:           "Take photo"
        case .library:          "Pick photo"
        case .photoAnalysis:    "Estimate"
        case .text:             "Describe meal"
        case .textAnalysis:     "Estimate"
        }
    }

    private func handleSelect(_ next: Screen) {
        screen = next
    }

    private func save(_ entry: NutritionEntry) {
        Task {
            await services.recordNutritionEntry(entry)
            dismiss()
        }
    }
}

// MARK: - Step 1: pick a mode

private struct ModePicker: View {
    let canScanBarcode: Bool
    let hasAPIKey: Bool
    let onSelect: (AddNutritionEntrySheet.Screen) -> Void

    var body: some View {
        List {
            Section {
                Button { onSelect(.barcode) } label: {
                    AddRow(systemImage: "barcode.viewfinder", title: "Scan barcode",
                           subtitle: "Packaged foods via Open Food Facts (free).")
                }
                .disabled(!canScanBarcode)
            } footer: {
                if !canScanBarcode {
                    Text("Barcode scanning needs a device camera. The simulator does not support it.")
                        .font(.caption2)
                }
            }
            Section {
                Button { onSelect(.camera) } label: {
                    AddRow(systemImage: "camera", title: "Take photo",
                           subtitle: "Snap a meal — AI estimates the nutrition.")
                }
                Button { onSelect(.library) } label: {
                    AddRow(systemImage: "photo", title: "Pick from photos",
                           subtitle: "Choose an existing photo.")
                }
                Button { onSelect(.text) } label: {
                    AddRow(systemImage: "text.bubble", title: "Describe in text",
                           subtitle: "Type what you ate — fast for things you remember.")
                }
            } footer: {
                if !hasAPIKey {
                    Text("Photo and text analysis need an OpenRouter API key. Add it in the Data tab.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct AddRow: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Barcode flow

private struct BarcodeStep: View {
    let onScanned: (OpenFoodFactsProduct) -> Void
    let onError: (String) -> Void
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if BarcodeScannerView.isSupported {
                BarcodeScannerView { payload in
                    guard !isLoading else { return }
                    isLoading = true
                    Task {
                        do {
                            let product = try await OpenFoodFactsClient.lookup(barcode: payload)
                            await MainActor.run { onScanned(product) }
                        } catch {
                            await MainActor.run {
                                onError(error.localizedDescription)
                                isLoading = false
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Camera unavailable",
                    systemImage: "camera.metering.unknown",
                    description: Text("Barcode scanning needs a device camera.")
                )
            }
            if isLoading {
                ProgressView("Looking up product…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct BarcodeConfirmStep: View {
    let product: OpenFoodFactsProduct
    let onSave: (NutritionEntry) -> Void

    @State private var portionInput: Double?
    @FocusState private var focused: Bool

    var body: some View {
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
                        value: $portionInput,
                        format: .number
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .frame(maxWidth: 120)
                }
                if let s = product.servingSizeGrams {
                    Text("Package serving: \(Int(s)) g").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Per-100 g (from Open Food Facts)") {
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
                    let portion = portionInput ?? product.servingSizeGrams ?? 100
                    let scaled  = product.scaled(toGrams: portion)
                    let entry = NutritionEntry(
                        date: .now,
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
                        costUSD: 0
                    )
                    onSave(entry)
                } label: {
                    Label("Save entry", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { focused = true }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }
}

// MARK: - Camera / library

private struct CapturePhotoStep: View {
    let mode: CameraPickerView.SourceMode
    let onPick: (UIImage?) -> Void

    var body: some View {
        CameraPickerView(mode: mode) { image in
            onPick(image)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Text input

private struct TextStep: View {
    @Binding var text: String
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section("Describe what you ate") {
                TextField(
                    "e.g. Big bowl of pasta carbonara with side salad",
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .focused($focused)
            }
            Section {
                Button {
                    onSubmit()
                } label: {
                    Label("Estimate nutrition", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Text is sent to OpenRouter using the model configured in the Data tab.")
                    .font(.caption2)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Analyze (photo or text)

private struct AnalyzeStep: View {
    @Environment(AppServices.self) private var services

    let text: String
    let image: UIImage?
    let onSave: (NutritionEntry) -> Void

    @State private var isLoading = true
    @State private var error: String?
    @State private var completed: CompletedAnalysis?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Estimating nutrition…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(
                    "Could not analyse",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if let completed {
                resultView(completed)
            } else {
                ProgressView()
            }
        }
        .task { await analyze() }
    }

    private func analyze() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let jpeg = image?.jpegForAnalysis()
            let result = try await services.openRouter.analyzeMeal(imageJPEG: jpeg, freeText: text)
            completed = result
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func resultView(_ c: CompletedAnalysis) -> some View {
        Form {
            if let img = image {
                Section {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Section("Estimated") {
                if let name = c.result.productName { row("Meal", name) }
                row("Portion",        c.result.portionGrams.map { String(format: "%.0f g", $0) })
                row("Protein",        c.result.proteinGrams.map { String(format: "%.0f g", $0) })
                row("Fibre",          c.result.fiberGrams.map { String(format: "%.0f g", $0) })
                row("Carbs",          c.result.carbsGrams.map { String(format: "%.0f g", $0) })
                row("Fat",            c.result.fatGrams.map { String(format: "%.0f g", $0) })
                row("Saturated fat",  c.result.saturatedFatGrams.map { String(format: "%.0f g", $0) })
                row("Added sugar",    c.result.addedSugarGrams.map { String(format: "%.0f g", $0) })
                row("Sodium",         c.result.sodiumMilligrams.map { String(format: "%.0f mg", $0) })
                row("Fatty fish",     c.result.isFattyFish.map { $0 ? "yes" : "no" })
                row("Leafy greens",   c.result.leafyGreenServings.map { String(format: "%.1f svg", $0) })
                row("Ultra-processed",c.result.ultraProcessedScore.map { String(format: "%.2f / 1.0", $0) })
                if let conf = c.result.confidence { row("Confidence", conf) }
            }
            if let notes = c.result.aiNotes, !notes.isEmpty {
                Section("AI assumptions") { Text(notes).font(.footnote) }
            }
            Section("Cost") {
                row("Tokens", "\(c.inputTokens) in / \(c.outputTokens) out")
                row("Cost",   String(format: "$%.4f", c.costUSD))
                row("Model",  c.model)
            }
            Section {
                Button {
                    let r = c.result
                    let entry = NutritionEntry(
                        date: .now,
                        source: image != nil ? .photo : .text,
                        rawInput: text,
                        productName: r.productName,
                        portionGrams: r.portionGrams,
                        proteinGrams: r.proteinGrams,
                        fiberGrams: r.fiberGrams,
                        carbsGrams: r.carbsGrams,
                        fatGrams: r.fatGrams,
                        saturatedFatGrams: r.saturatedFatGrams,
                        addedSugarGrams: r.addedSugarGrams,
                        sodiumMilligrams: r.sodiumMilligrams,
                        isFattyFish: r.isFattyFish,
                        leafyGreenServings: r.leafyGreenServings,
                        ultraProcessedScore: r.ultraProcessedScore,
                        aiNotes: r.aiNotes,
                        modelUsed: c.model,
                        inputTokens: c.inputTokens,
                        outputTokens: c.outputTokens,
                        costUSD: c.costUSD
                    )
                    onSave(entry)
                } label: {
                    Label("Save entry", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
}
