import SwiftUI
import UIKit

struct NutritionEntryDetailView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Bindable var entry: NutritionEntry

    @State private var showDeleteConfirm = false
    @State private var showEditSheet = false
    @State private var photo: UIImage?

    var body: some View {
        Form {
            if let photo {
                Section {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Source") {
                HStack {
                    Image(systemName: entry.source.systemImage)
                    Text(entry.source.displayLabel)
                    Spacer()
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !entry.rawInput.isEmpty {
                    Text(entry.rawInput).font(.subheadline)
                }
                if let notes = entry.aiNotes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(notes).font(.footnote)
                    }
                }
            }

            if let fp = entry.fingerprint {
                fingerprintSections(fp)
            } else if hasMacros {
                macroSection
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete entry", systemImage: "trash")
                }
            }
        }
        .navigationTitle(entry.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showEditSheet = true }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditNutritionEntrySheet(entry: entry)
        }
        .alert("Delete this entry?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    await services.deleteNutritionEntry(entry)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: entry.imageFileName) {
            photo = MealImageStore.image(for: entry.imageFileName)
        }
    }

    private var hasMacros: Bool {
        entry.portionGrams != nil || entry.proteinGrams != nil || entry.fiberGrams != nil
    }

    @ViewBuilder
    private func fingerprintSections(_ fp: MealFingerprint) -> some View {
        Section("Categories on plate") {
            if fp.items.isEmpty {
                Text("No categories detected.").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(fp.items.sorted { $0.plateFraction > $1.plateFraction }, id: \.category) { item in
                    HStack {
                        Image(systemName: item.category.systemImage).frame(width: 22)
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
                Text(fp.plantIngredients.joined(separator: ", ")).font(.subheadline)
            }
        }
    }

    private var macroSection: some View {
        Section("Nutrients") {
            row("Portion",         entry.portionGrams.map { String(format: "%.0f g", $0) })
            row("Protein",         entry.proteinGrams.map { String(format: "%.0f g", $0) })
            row("Fibre",           entry.fiberGrams.map { String(format: "%.0f g", $0) })
            row("Carbs",           entry.carbsGrams.map { String(format: "%.0f g", $0) })
            row("Fat",             entry.fatGrams.map { String(format: "%.0f g", $0) })
            row("Saturated fat",   entry.saturatedFatGrams.map { String(format: "%.0f g", $0) })
            row("Added sugar",     entry.addedSugarGrams.map { String(format: "%.0f g", $0) })
            row("Sodium",          entry.sodiumMilligrams.map { String(format: "%.0f mg", $0) })
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
