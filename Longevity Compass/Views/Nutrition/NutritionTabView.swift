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
    @State private var libraryImage: UIImage?

    private struct CapturedImage: Identifiable {
        let id = UUID()
        let image: UIImage
        let date: Date
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                cameraPanel
                    .frame(height: max(360, geo.size.height * 0.60))
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
        }
        .sheet(item: $captured) { item in
            PostCaptureSheet(image: item.image, capturedAt: item.date) { outcome in
                handleSheetOutcome(outcome)
            }
        }
        .sheet(isPresented: $showLibraryPicker) {
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
                showLibraryPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.18), in: Circle())
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
            .disabled(isCapturing || services.mealCapture.authorization != .granted)

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
        .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Weekly panel

    @ViewBuilder
    private var weeklyPanel: some View {
        if let digest = services.nutritionDigest {
            ScrollView {
                NutritionRollupPanel(digest: digest)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            Color(.systemGroupedBackground)
                .overlay(
                    Text("Snap your first meal to get started.")
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
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            let image = try await services.mealCapture.capturePhoto()
            captured = CapturedImage(image: image, date: .now)
        } catch {
            flash("Could not capture photo")
        }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        if let fp = entry.fingerprint {
            let topCategories = fp.items
                .sorted { $0.plateFraction > $1.plateFraction }
                .prefix(3)
                .map(\.category.displayLabel)
            if !topCategories.isEmpty {
                return topCategories.joined(separator: " · ")
            }
            if !fp.plantIngredients.isEmpty {
                return fp.plantIngredients.prefix(3).joined(separator: ", ")
            }
            return entry.source.displayLabel
        }
        var parts: [String] = []
        if let p = entry.portionGrams { parts.append("\(Int(p.rounded())) g") }
        if let p = entry.proteinGrams { parts.append("P \(Int(p.rounded()))") }
        if let f = entry.fiberGrams   { parts.append("F \(Int(f.rounded()))") }
        if let s = entry.addedSugarGrams { parts.append("Sug \(Int(s.rounded()))") }
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

// MARK: - Rollup panel (unchanged from previous file)

struct NutritionRollupPanel: View {
    let digest: NutritionDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week — \(digest.coverageDays)/\(digest.lookbackDays) days logged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "$%.3f this month", digest.costThisMonthUSD))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if digest.coverageDays < HealthThresholds.Nutrition.minDaysWithDataForRollup {
                Text("Log a few more meals before this becomes meaningful.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(digest.rollups) { rollup in
                    BucketRow(rollup: rollup)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct BucketRow: View {
    let rollup: NutritionBucketRollup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rollup.bucket.systemImage)
                .frame(width: 24)
                .foregroundStyle(rollup.bucket.lowerIsBetter ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(rollup.bucket.displayLabel)
                    .font(.subheadline.weight(.semibold))
                Text(rollup.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            BucketStatusBadge(status: rollup.status)
        }
    }
}

private struct BucketStatusBadge: View {
    let status: BucketStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
            Text(status.displayLabel)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .ok:                .green
        case .veryLow, .low:     .orange
        case .high:              .orange
        case .veryHigh:          .red
        case .unknown:           .gray
        }
    }
}
