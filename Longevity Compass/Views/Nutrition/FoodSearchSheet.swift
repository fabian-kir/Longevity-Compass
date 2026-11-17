import SwiftUI

struct FoodSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSaved: (String) -> Void

    @State private var query = ""
    @State private var results: [OpenFoodFactsProduct] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            content
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Product name or brand"
                )
                .onSubmit(of: .search) { Task { await runSearch() } }
                .navigationTitle("Search food")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if hasSearched && results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if !hasSearched {
            ContentUnavailableView(
                "Search for a product",
                systemImage: "magnifyingglass",
                description: Text("Type a product name or brand, then tap Search.")
            )
        } else {
            List {
                Section {
                    ForEach(results, id: \.barcode) { product in
                        NavigationLink {
                            ProductConfirmView(product: product) { savedTitle in
                                onSaved(savedTitle)
                                dismiss()
                            }
                        } label: {
                            ProductSearchRow(product: product)
                        }
                    }
                } footer: {
                    OpenFoodFactsAttribution()
                }
            }
            .listStyle(.plain)
        }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await OpenFoodFactsClient.search(query: trimmed)
            hasSearched = true
        } catch {
            errorMessage = error.localizedDescription
            hasSearched = true
        }
    }
}

// MARK: - List row

private struct ProductSearchRow: View {
    let product: OpenFoodFactsProduct

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url = product.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(product.name ?? "Unknown product")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let brand = product.brand {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let kcal = product.kcal100g {
                    Text(String(format: "%.0f kcal / 100 g", kcal))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var placeholder: some View {
        Color(.tertiarySystemFill)
            .overlay(Image(systemName: "fork.knife").foregroundStyle(.secondary))
    }
}

// MARK: - Product confirm

struct DetectedBarcodeProductSheet: View {
    @Environment(\.dismiss) private var dismiss

    let product: OpenFoodFactsProduct
    let detectedAt: Date
    let onSaved: (String) -> Void

    var body: some View {
        NavigationStack {
            ProductConfirmView(product: product, loggedAt: detectedAt, onSaved: onSaved)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

struct ProductConfirmView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let product: OpenFoodFactsProduct
    let loggedAt: Date
    let onSaved: (String) -> Void

    @State private var portionGrams: Double
    @State private var isSaving = false

    init(
        product: OpenFoodFactsProduct,
        loggedAt: Date = .now,
        onSaved: @escaping (String) -> Void
    ) {
        self.product = product
        self.loggedAt = loggedAt
        self.onSaved = onSaved
        self._portionGrams = State(initialValue: product.servingSizeGrams ?? 100)
    }

    var body: some View {
        Form {
            Section("Product") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name ?? "Unknown product")
                        .font(.headline)
                        .lineLimit(2)
                    if let brand = product.brand {
                        Text(brand).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(product.barcode).font(.caption2).foregroundStyle(.tertiary)
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
                    Text("Package serving: \(Int(s)) g")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let v = product.kcal100g   { row("Calories",      String(format: "%.0f kcal", v)) }
                if let v = product.protein100g { row("Protein",       String(format: "%.1f g", v)) }
                if let v = product.carbs100g   { row("Carbs",         String(format: "%.1f g", v)) }
                if let v = product.fat100g     { row("Fat",           String(format: "%.1f g", v)) }
                if let v = product.fiber100g   { row("Fibre",         String(format: "%.1f g", v)) }
                if let v = product.satFat100g  { row("Saturated fat", String(format: "%.1f g", v)) }
                if let v = product.sugars100g  { row("Sugars",        String(format: "%.1f g", v)) }
                if let n = product.novaGroup   { row("NOVA group",    "\(n) / 4") }
            } header: {
                Text("Per 100 g (Open Food Facts)")
            } footer: {
                OpenFoodFactsAttribution()
            }

            Section {
                Button { save() } label: {
                    Label("Save entry", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .navigationTitle(product.name ?? "Product")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let scaled = product.scaled(toGrams: portionGrams)
            let entry = NutritionEntry(
                date: loggedAt,
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
                ultraProcessedScore: product.ultraProcessedScore,
                modelUsed: "openfoodfacts",
                costUSD: 0
            )
            await services.recordNutritionEntry(entry)
            onSaved(product.name ?? "product")
            dismiss()
        }
    }
}

/// ODbL attribution shown wherever Open Food Facts data appears.
struct OpenFoodFactsAttribution: View {
    var body: some View {
        Link(destination: URL(string: "https://world.openfoodfacts.org")!) {
            Text("Data © Open Food Facts contributors (ODbL)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
