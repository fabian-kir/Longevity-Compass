import SwiftUI

struct AddBloodworkPanelSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = .now
    @State private var labName: String = ""
    @State private var notes: String = ""
    @State private var acutePhase: Bool = false
    @State private var drafts: [MarkerDraft] = BloodworkMarkerCatalog.defaults.map(MarkerDraft.init)

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
                    Toggle("Drawn during illness or injury", isOn: $acutePhase)
                        .toggleStyle(.switch)
                }

                ForEach(BloodworkMarkerCatalog.Tier.allCases) { tier in
                    markerSection(for: tier)
                }

                if !customDrafts.isEmpty {
                    Section {
                        ForEach(customIndices, id: \.self) { idx in
                            MarkerDraftRow(
                                draft: $drafts[idx],
                                acutePhase: acutePhase,
                                profile: services.healthSnapshot,
                                onShowDetail: nil
                            )
                        }
                        .onDelete(perform: deleteCustomMarkers)
                    } header: {
                        Text("Custom")
                    } footer: {
                        Text("Custom markers aren't in the reference library, so the app stores them without a status.")
                    }
                }

                Section {
                    Button {
                        showAddCustom = true
                    } label: {
                        Label("Add custom marker", systemImage: "plus.circle")
                    }
                } footer: {
                    Text(acutePhase
                         ? "Acute-phase reactants (hs-CRP, ferritin, albumin) will be stored but not flagged — their interpretation is unreliable when you're sick."
                         : "Leave any row blank if you didn't test it — only filled rows are saved. The app evaluates each value against research-backed bands using your age and biological sex.")
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
                        acutePhase: acutePhase,
                        profile: services.healthSnapshot,
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
            id: UUID().uuidString,
            name: trimmedName,
            unitOptions: [trimmedUnit],
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
                flag: .unknown
            )
        }
        let panel = BloodworkPanel(
            date: date,
            labName: labName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : labName,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes,
            acutePhaseAtDraw: acutePhase,
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
    let id: String
    var name: String
    /// Units the user can choose from. Primary first, then any alternates the
    /// research JSON declares for this marker (e.g. mg/dL, mmol/L for LDL-C).
    var unitOptions: [String]
    var unit: String
    var tier: BloodworkMarkerCatalog.Tier?     // nil → custom marker
    var purpose: String?
    var detail: String?
    var value: String = ""

    init(
        id: String,
        name: String,
        unitOptions: [String],
        unit: String,
        tier: BloodworkMarkerCatalog.Tier?,
        purpose: String?,
        detail: String?,
        value: String = ""
    ) {
        self.id = id
        self.name = name
        self.unitOptions = unitOptions.filter { !$0.isEmpty }
        self.unit = unit
        self.tier = tier
        self.purpose = purpose
        self.detail = detail
        self.value = value
    }

    init(_ suggestion: BloodworkMarkerCatalog.Suggestion) {
        let entry = BloodworkResearch.entry(for: suggestion.name)
        let alternates = entry?.unit.alternates.map(\.unit) ?? []
        var options = [suggestion.unit]
        for alt in alternates where !options.contains(alt) {
            options.append(alt)
        }
        self.init(
            id: suggestion.id,
            name: suggestion.name,
            unitOptions: options,
            unit: suggestion.unit,
            tier: suggestion.tier,
            purpose: suggestion.purpose,
            detail: suggestion.detail
        )
    }
}

private struct MarkerDraftRow: View {
    @Binding var draft: MarkerDraft
    let acutePhase: Bool
    let profile: HealthKitSnapshot
    let onShowDetail: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                unitControl
            }
            if let purpose = draft.purpose {
                Text(purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !draft.value.trimmingCharacters(in: .whitespaces).isEmpty {
                livePreview
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var unitControl: some View {
        if draft.unitOptions.count > 1 {
            Menu {
                ForEach(draft.unitOptions, id: \.self) { option in
                    Button(option) { draft.unit = option }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(draft.unit)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .leading)
            }
        } else {
            Text(draft.unit)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .leading)
        }
    }

    @ViewBuilder
    private var livePreview: some View {
        let result = BloodworkEvaluator.evaluate(
            markerName: draft.name,
            rawValue: draft.value,
            unit: draft.unit,
            sex: profile.biologicalSex,
            dateOfBirth: profile.dateOfBirth,
            acutePhaseAtDraw: acutePhase
        )
        HStack(spacing: 6) {
            Circle()
                .fill(tint(for: result.flag))
                .frame(width: 8, height: 8)
            if let band = result.band {
                Text("\(result.flag.displayLabel) · \(band.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let reason = result.suppressedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Logged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tint(for flag: BloodworkFlag) -> Color {
        switch flag {
        case .good:       .green
        case .borderline: .orange
        case .bad:        .red
        case .unknown:    .gray
        }
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
