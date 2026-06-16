import SwiftUI

struct AddBloodworkPanelSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = .now
    @State private var labName: String = ""
    @State private var notes: String = ""
    @State private var drafts: [MarkerDraft] = BloodworkMarkerCatalog.defaults.map {
        MarkerDraft(
            name: $0.name,
            unit: $0.unit,
            tier: $0.tier,
            purpose: $0.purpose,
            detail: $0.detail
        )
    }

    @State private var showAddCustom = false
    @State private var customName = ""
    @State private var customUnit = ""
    @State private var detailMarker: MarkerDraft?

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Draw date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    TextField("Lab name (optional)", text: $labName)
                }

                ForEach(BloodworkMarkerCatalog.Tier.allCases) { tier in
                    markerSection(for: tier)
                }

                if !customDrafts.isEmpty {
                    Section {
                        ForEach(customIndices, id: \.self) { idx in
                            MarkerDraftRow(
                                draft: $drafts[idx],
                                onShowDetail: nil
                            )
                        }
                        .onDelete(perform: deleteCustomMarkers)
                    } header: {
                        Text("Custom")
                    }
                }

                Section {
                    Button {
                        showAddCustom = true
                    } label: {
                        Label("Add custom marker", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("Leave any row blank if you didn't test it — only filled rows are saved. Flag each result good / borderline / bad based on your lab's reference range.")
                }

                Section("Notes") {
                    TextField("Anything to remember (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("New Panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!hasAnyResults)
                }
            }
            .alert("Add marker", isPresented: $showAddCustom) {
                TextField("Name", text: $customName)
                TextField("Unit (optional)", text: $customUnit)
                Button("Add") { addCustomMarker() }
                Button("Cancel", role: .cancel) { resetCustomInputs() }
            }
            .sheet(item: $detailMarker) { draft in
                MarkerDetailSheet(draft: draft)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func markerSection(for tier: BloodworkMarkerCatalog.Tier) -> some View {
        let indices = drafts.indices.filter { drafts[$0].tier == tier }
        if !indices.isEmpty {
            Section {
                ForEach(indices, id: \.self) { idx in
                    MarkerDraftRow(
                        draft: $drafts[idx],
                        onShowDetail: { detailMarker = drafts[idx] }
                    )
                }
            } header: {
                HStack {
                    Text(tier.title)
                    Spacer()
                    tierBadge(tier)
                }
            } footer: {
                Text(tier.subtitle)
            }
        }
    }

    @ViewBuilder
    private func tierBadge(_ tier: BloodworkMarkerCatalog.Tier) -> some View {
        Text(tier == .core ? "MUST" : tier == .extended ? "NICE" : "OPTIONAL")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tierTint(tier))
            .glassChip(tint: tierTint(tier), tintOpacity: 0.25)
    }

    private func tierTint(_ tier: BloodworkMarkerCatalog.Tier) -> Color {
        switch tier {
        case .core:        .red
        case .extended:    .orange
        case .specialized: .gray
        }
    }

    // MARK: - Custom helpers

    private var customIndices: [Int] {
        drafts.indices.filter { drafts[$0].tier == nil }
    }

    private var customDrafts: [MarkerDraft] {
        drafts.filter { $0.tier == nil }
    }

    private func deleteCustomMarkers(at offsets: IndexSet) {
        let targets = offsets.map { customIndices[$0] }
        // Delete from highest to lowest so earlier indices remain valid.
        for i in targets.sorted(by: >) {
            drafts.remove(at: i)
        }
    }

    private var hasAnyResults: Bool {
        drafts.contains { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func addCustomMarker() {
        let trimmedName = customName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { resetCustomInputs(); return }
        let trimmedUnit = customUnit.trimmingCharacters(in: .whitespaces)
        drafts.append(MarkerDraft(
            name: trimmedName,
            unit: trimmedUnit,
            tier: nil,
            purpose: nil,
            detail: nil
        ))
        resetCustomInputs()
    }

    private func resetCustomInputs() {
        customName = ""
        customUnit = ""
    }

    private func save() {
        let markers: [BloodworkMarker] = drafts.compactMap { draft in
            let trimmedValue = draft.value.trimmingCharacters(in: .whitespaces)
            guard !trimmedValue.isEmpty else { return nil }
            return BloodworkMarker(
                name: draft.name,
                value: trimmedValue,
                unit: draft.unit.isEmpty ? nil : draft.unit,
                referenceRange: nil,
                flag: draft.flag
            )
        }
        let panel = BloodworkPanel(
            date: date,
            labName: labName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : labName,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes,
            markers: markers
        )
        Task {
            await services.recordBloodworkPanel(panel)
            dismiss()
        }
    }
}

// MARK: - Marker draft

struct MarkerDraft: Identifiable {
    let id = UUID()
    var name: String
    var unit: String
    var tier: BloodworkMarkerCatalog.Tier?     // nil → custom marker
    var purpose: String?
    var detail: String?
    var value: String = ""
    var flag: BloodworkFlag = .unknown
}

private struct MarkerDraftRow: View {
    @Binding var draft: MarkerDraft
    let onShowDetail: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.name)
                    .font(.subheadline.weight(.semibold))
                if onShowDetail != nil {
                    Button {
                        onShowDetail?()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("—", text: $draft.value)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                Text(draft.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 50, alignment: .leading)
            }
            if let purpose = draft.purpose {
                Text(purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !draft.value.trimmingCharacters(in: .whitespaces).isEmpty {
                Picker("Flag", selection: $draft.flag) {
                    ForEach(BloodworkFlag.allCases) { flag in
                        Text(flag.displayLabel).tag(flag)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Per-marker detail sheet

private struct MarkerDetailSheet: View {
    let draft: MarkerDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let tier = draft.tier {
                    Section {
                        LabeledContent("Tier", value: tier.title)
                        if !draft.unit.isEmpty {
                            LabeledContent("Typical unit", value: draft.unit)
                        }
                    }
                }
                if let purpose = draft.purpose {
                    Section("Why it matters") {
                        Text(purpose)
                            .font(.subheadline)
                    }
                }
                if let detail = draft.detail {
                    Section("Detail") {
                        Text(detail)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
