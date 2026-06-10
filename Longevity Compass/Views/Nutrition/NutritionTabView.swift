import SwiftUI
import SwiftData

struct NutritionTabView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \NutritionEntry.date, order: .reverse) private var entries: [NutritionEntry]

    @State private var showAddSheet = false

    var body: some View {
        List {
            Section {
                if let digest = services.nutritionDigest {
                    NutritionRollupPanel(digest: digest)
                } else {
                    Text("Nothing logged in the last \(HealthThresholds.Nutrition.rollupDays) days.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } header: {
                Text("Last \(HealthThresholds.Nutrition.rollupDays) days")
            }

            Section {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No entries yet",
                        systemImage: "fork.knife",
                        description: Text("Scan a barcode, snap a photo, or describe a meal in text.")
                    )
                } else {
                    ForEach(entries) { entry in
                        NutritionEntryRow(entry: entry)
                    }
                    .onDelete { offsets in
                        Task {
                            for index in offsets {
                                await services.deleteNutritionEntry(entries[index])
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent entries")
                    Spacer()
                    if !entries.isEmpty {
                        Text("\(entries.count) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Nutrition")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddNutritionEntrySheet()
        }
    }
}

// MARK: - Rollup panel

struct NutritionRollupPanel: View {
    let digest: NutritionDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(digest.coverageDays)/\(digest.lookbackDays) days logged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "$%.3f this month", digest.costThisMonthUSD))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if digest.coverageDays < HealthThresholds.Nutrition.minDaysWithDataForRollup {
                Text("Log a few more days before the buckets become meaningful.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(digest.rollups) { rollup in
                    BucketRow(rollup: rollup)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BucketRow: View {
    let rollup: NutritionBucketRollup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rollup.bucket.systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)
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

// MARK: - Entry row

private struct NutritionEntryRow: View {
    let entry: NutritionEntry

    var body: some View {
        NavigationLink {
            NutritionEntryDetailView(entry: entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.source.systemImage)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
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
        var parts: [String] = []
        if let p = entry.portionGrams { parts.append("\(Int(p.rounded())) g") }
        if let p = entry.proteinGrams { parts.append("P \(Int(p.rounded()))") }
        if let f = entry.fiberGrams   { parts.append("F \(Int(f.rounded()))") }
        if let s = entry.addedSugarGrams { parts.append("Sug \(Int(s.rounded()))") }
        return parts.joined(separator: " · ")
    }
}
