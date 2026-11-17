import SwiftUI
import SwiftData
import UIKit

struct NutritionTabView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Query(sort: \NutritionEntry.date, order: .reverse) private var entries: [NutritionEntry]

    @State private var captured: CapturedImage?
    @State private var savedNotice: String?
    @State private var isCapturing = false
    @State private var showLibraryPicker = false
    @State private var showFoodSearch = false
    @State private var libraryImage: UIImage?
    @State private var detectedProduct: DetectedProduct?
    @State private var isResolvingBarcode = false

    private struct CapturedImage: Identifiable {
        let id = UUID()
        let image: UIImage
        let date: Date
    }

    private struct DetectedProduct: Identifiable {
        let id = UUID()
        let product: OpenFoodFactsProduct
        let detectedAt: Date
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                cameraPanel
                    .frame(height: min(max(280, geo.size.height * 0.38), 380))
                weeklyPanel
            }
        }
        .navigationTitle("Nutrition")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NutritionHistoryView()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    services.mealCapture.suspendBarcodeDetection()
                    showFoodSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .sheet(item: $captured, onDismiss: resumeBarcodeDetection) { item in
            PostCaptureSheet(image: item.image, capturedAt: item.date) { outcome in
                handleSheetOutcome(outcome)
            }
        }
        .sheet(item: $detectedProduct, onDismiss: resumeBarcodeDetection) { item in
            DetectedBarcodeProductSheet(
                product: item.product,
                detectedAt: item.detectedAt
            ) { title in
                detectedProduct = nil
                flash("Logged \(title)")
            }
        }
        .sheet(isPresented: $showFoodSearch, onDismiss: resumeBarcodeDetection) {
            FoodSearchSheet { title in
                flash("Logged \(title)")
            }
        }
        .sheet(isPresented: $showLibraryPicker, onDismiss: resumeBarcodeDetection) {
            CameraPickerView(mode: .library) { image in
                showLibraryPicker = false
                if let image {
                    captured = CapturedImage(image: image, date: .now)
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { toast }
        .task { await services.mealCapture.start() }
        // Not `.task(id:)`: resolveBarcode consumes the detection, which changes
        // the id and would cancel its own in-flight lookup request.
        .onChange(of: services.mealCapture.detectedBarcode?.id) {
            guard let detection = services.mealCapture.detectedBarcode else { return }
            Task { await resolveBarcode(detection) }
        }
        .onDisappear { services.mealCapture.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await services.mealCapture.start() }
            } else {
                services.mealCapture.stop()
            }
        }
    }

    // MARK: - Camera panel

    @ViewBuilder
    private var cameraPanel: some View {
        ZStack {
            switch services.mealCapture.authorization {
            case .granted:
                CameraPreviewView(session: services.mealCapture.session)
                    .ignoresSafeArea(edges: .horizontal)
            case .denied, .restricted:
                permissionDeniedView
            case .undetermined:
                Color.black
                    .overlay(ProgressView().tint(.white))
            }

            VStack {
                HStack {
                    if !services.pendingMeals.pending.isEmpty {
                        pendingBadge
                    }
                    Spacer()
                }
                Spacer()
                shutterRow
            }
            .padding()
        }
        .background(Color.black)
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.8))
            Text("Camera access is off")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Use the library, or enable camera access in Settings.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button {
                    services.mealCapture.suspendBarcodeDetection()
                    showLibraryPicker = true
                } label: {
                    Label("Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("Open Settings")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var shutterRow: some View {
        HStack {
            Button {
                services.mealCapture.suspendBarcodeDetection()
                showLibraryPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .glassEffect(.regular.tint(.white.opacity(0.12)), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.30), lineWidth: 0.8))
            }

            Spacer()

            Button {
                Task { await snap() }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 62, height: 62)
                        .opacity(isCapturing ? 0.4 : 1.0)
                }
            }
            .disabled(
                isCapturing
                || isResolvingBarcode
                || services.mealCapture.authorization != .granted
            )

            Spacer()

            Color.clear.frame(width: 44, height: 44) // visual symmetry
        }
    }

    private var pendingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: services.pendingMeals.isOnline ? "icloud.and.arrow.up" : "wifi.slash")
            Text("\(services.pendingMeals.pending.count) pending")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 0.6))
    }

    // MARK: - Weekly panel

    @ViewBuilder
    private var weeklyPanel: some View {
        if let digest = services.nutritionDigest {
            ScrollView {
                NutritionDashboardView(digest: digest)
                    .padding(.horizontal)
                    .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            Color(.systemGroupedBackground)
                .overlay(
                    ProgressView("Building your food pattern…")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                )
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toast: some View {
        if let notice = savedNotice {
            Text(notice)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func snap() async {
        guard !isCapturing, !isResolvingBarcode, detectedProduct == nil else { return }
        services.mealCapture.suspendBarcodeDetection()
        isCapturing = true
        defer { isCapturing = false }
        do {
            let image = try await services.mealCapture.capturePhoto()
            captured = CapturedImage(image: image, date: .now)
        } catch {
            services.mealCapture.resumeBarcodeDetection()
            flash("Could not capture photo")
        }
    }

    private func resolveBarcode(_ detection: MealCaptureCoordinator.BarcodeDetection) async {
        guard captured == nil,
              detectedProduct == nil,
              !showLibraryPicker,
              !showFoodSearch,
              !isCapturing,
              !isResolvingBarcode
        else { return }

        isResolvingBarcode = true
        services.mealCapture.consumeBarcodeDetection(id: detection.id)
        defer { isResolvingBarcode = false }

        do {
            let product = try await OpenFoodFactsClient.lookup(barcode: detection.payload)
            detectedProduct = DetectedProduct(product: product, detectedAt: detection.detectedAt)
        } catch {
            // A short toast tells the user the code was read, so an unknown
            // product or a failed lookup is not mistaken for a scanner that
            // never sees anything. The camera then returns to recognition mode.
            if case OpenFoodFactsError.notFound = error {
                flash("Barcode \(detection.payload) not in Open Food Facts")
            } else {
                flash("Barcode lookup failed: \(error.localizedDescription)")
            }
            services.mealCapture.resumeBarcodeDetection()
        }
    }

    private func resumeBarcodeDetection() {
        services.mealCapture.resumeBarcodeDetection()
    }

    private func handleSheetOutcome(_ outcome: PostCaptureSheet.Outcome) {
        captured = nil
        switch outcome {
        case .saved(let title):       flash("Logged \(title)")
        case .queued:                 flash("Saved — will analyse when online")
        case .cancelled, .failed:     break
        }
    }

    private func flash(_ text: String) {
        withAnimation { savedNotice = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { savedNotice = nil }
        }
    }
}

// MARK: - History destination

struct NutritionHistoryView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \NutritionEntry.date, order: .reverse) private var entries: [NutritionEntry]

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No entries yet",
                    systemImage: "fork.knife",
                    description: Text("Snap a meal from the Nutrition tab to log it.")
                )
            } else {
                ForEach(entries) { entry in
                    NutritionHistoryRow(entry: entry)
                }
                .onDelete { offsets in
                    Task {
                        for index in offsets {
                            await services.deleteNutritionEntry(entries[index])
                        }
                    }
                }
            }
        }
        .navigationTitle("Nutrition history")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NutritionHistoryRow: View {
    let entry: NutritionEntry

    var body: some View {
        NavigationLink {
            NutritionEntryDetailView(entry: entry)
        } label: {
            HStack(spacing: 12) {
                MealThumbnailView(fileName: entry.imageFileName, fallback: entry.source.systemImage)
                // The date sits under the title instead of in a trailing
                // column, so meal names get the full row width.
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var detail: String {
        if let fp = entry.fingerprint {
            var parts: [String] = []
            if let kcal = entry.caloriesKcal {
                parts.append("\(Int(kcal.rounded())) kcal")
            }
            let maxCategories = parts.isEmpty ? 3 : 2
            let topCategories = fp.items
                .sorted { $0.plateFraction > $1.plateFraction }
                .prefix(maxCategories)
                .map(\.category.displayLabel)
            if !topCategories.isEmpty {
                parts.append(contentsOf: topCategories)
            } else if !fp.plantIngredients.isEmpty {
                parts.append(contentsOf: fp.plantIngredients.prefix(maxCategories).map { $0 })
            }
            return parts.isEmpty ? entry.source.displayLabel : parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if let kcal = entry.caloriesKcal   { parts.append("\(Int(kcal.rounded())) kcal") }
        if let p = entry.portionGrams       { parts.append("\(Int(p.rounded())) g") }
        if let p = entry.proteinGrams       { parts.append("P \(Int(p.rounded()))") }
        if let f = entry.fiberGrams         { parts.append("F \(Int(f.rounded()))") }
        return parts.joined(separator: " · ")
    }
}

/// 44pt square thumbnail for meal history. Falls back to a system glyph when the
/// entry has no on-disk image (legacy entries, or barcode entries logged before
/// image persistence shipped).
struct MealThumbnailView: View {
    let fileName: String?
    let fallback: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallback)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: fileName) {
            image = MealImageStore.image(for: fileName)
        }
    }
}
