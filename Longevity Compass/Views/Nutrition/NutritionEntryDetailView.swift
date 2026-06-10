import SwiftUI

struct NutritionEntryDetailView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let entry: NutritionEntry

    @State private var showDeleteConfirm = false

    var body: some View {
        Form {
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

            Section("Estimated nutrients") {
                row("Portion",         entry.portionGrams.map { String(format: "%.0f g", $0) })
                row("Protein",         entry.proteinGrams.map { String(format: "%.0f g", $0) })
                row("Fibre",           entry.fiberGrams.map { String(format: "%.0f g", $0) })
                row("Carbs",           entry.carbsGrams.map { String(format: "%.0f g", $0) })
                row("Fat",             entry.fatGrams.map { String(format: "%.0f g", $0) })
                row("Saturated fat",   entry.saturatedFatGrams.map { String(format: "%.0f g", $0) })
                row("Added sugar",     entry.addedSugarGrams.map { String(format: "%.0f g", $0) })
                row("Sodium",          entry.sodiumMilligrams.map { String(format: "%.0f mg", $0) })
                row("Fatty fish",      entry.isFattyFish.map { $0 ? "yes" : "no" })
                row("Leafy greens",    entry.leafyGreenServings.map { String(format: "%.1f svg", $0) })
                row("Ultra-processed", entry.ultraProcessedScore.map { String(format: "%.2f / 1.0", $0) })
            }

            if entry.modelUsed != nil || entry.costUSD != nil {
                Section("Model") {
                    if let m = entry.modelUsed { row("Model", m) }
                    if let cost = entry.costUSD { row("Cost", String(format: "$%.4f", cost)) }
                    if let ti = entry.inputTokens, let to = entry.outputTokens {
                        row("Tokens", "\(ti) in / \(to) out")
                    }
                }
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
        .alert("Delete this entry?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    await services.deleteNutritionEntry(entry)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
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
