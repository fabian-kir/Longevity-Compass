import SwiftUI

struct BloodworkPanelDetailView: View {
    @Environment(AppServices.self) private var services
    @Bindable var panel: BloodworkPanel
    @State private var editing: BloodworkMarker?

    var body: some View {
        Form {
            Section("Panel") {
                LabeledContent("Date", value: panel.date.formatted(date: .abbreviated, time: .omitted))
                if let lab = panel.labName, !lab.isEmpty {
                    LabeledContent("Lab", value: lab)
                }
                LabeledContent("Worst flag", value: panel.worstFlag.displayLabel)
                Toggle("Drawn during illness or injury", isOn: Binding(
                    get: { panel.acutePhaseAtDraw },
                    set: { newValue in
                        panel.acutePhaseAtDraw = newValue
                        Task { await services.reevaluateAndSaveBloodworkPanel(panel) }
                    }
                ))
                .toggleStyle(.switch)
            }

            if panel.acutePhaseAtDraw {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Acute-phase reactants (hs-CRP, ferritin, albumin) are stored but not flagged for this panel.")
                            .font(.footnote)
                    }
                }
            }

            Section("Markers") {
                ForEach(panel.markers.sorted { $0.name < $1.name }) { marker in
                    MarkerCard(
                        marker: marker,
                        profile: services.healthSnapshot,
                        acutePhase: panel.acutePhaseAtDraw,
                        onEdit: { editing = marker }
                    )
                }
            }

            if let notes = panel.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(panel.date.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { marker in
            MarkerEditSheet(marker: marker, panel: panel)
                .presentationDetents([.medium])
        }
    }
}

// MARK: - Marker card

private struct MarkerCard: View {
    @Bindable var marker: BloodworkMarker
    let profile: HealthKitSnapshot
    let acutePhase: Bool
    let onEdit: () -> Void

    @State private var expanded = false

    private var evaluation: BloodworkEvaluation {
        BloodworkEvaluator.evaluate(
            markerName: marker.name,
            rawValue: marker.value,
            unit: marker.unit,
            sex: profile.biologicalSex,
            dateOfBirth: profile.dateOfBirth,
            acutePhaseAtDraw: acutePhase
        )
    }

    private var entry: BloodworkMarkerEntry? {
        BloodworkResearch.entry(for: marker.name)
    }

    var body: some View {
        let result = evaluation
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(marker.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(marker.value)
                    .font(.subheadline)
                    .monospacedDigit()
                if let unit = marker.unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                statusBadge(for: result.flag)
            }

            if let band = result.band, let variant = result.variant {
                BandPositionBar(
                    variant: variant,
                    band: band,
                    value: result.parsedValue ?? 0
                )
                Text(verdictLine(result: result, band: band))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reason = result.suppressedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if entry != nil {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Hide details" : "Why this matters & how to improve")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                if expanded, let entry {
                    expandedSection(entry)
                }
            }

            Button(action: onEdit) {
                Label("Edit value", systemImage: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func expandedSection(_ entry: BloodworkMarkerEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.description)
                .font(.footnote)

            if !entry.easiestInterventions.isEmpty {
                bulletList(title: "How to improve", items: entry.easiestInterventions)
            }
            if !entry.causesHigh.isEmpty {
                bulletList(title: "Why it can be high", items: entry.causesHigh)
            }
            if !entry.causesLow.isEmpty {
                bulletList(title: "Why it can be low", items: entry.causesLow)
            }
            if !entry.sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sources")
                        .font(.caption.weight(.semibold))
                    ForEach(entry.sources, id: \.url) { source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                Text("\(source.publisher) — \(source.title)")
                                    .font(.caption2)
                                    .underline()
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func bulletList(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").font(.caption)
                    Text(item).font(.caption)
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func statusBadge(for flag: BloodworkFlag) -> some View {
        Text(flag.displayLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint(for: flag))
            .background(tint(for: flag).opacity(0.18))
            .clipShape(Capsule())
    }

    private func tint(for flag: BloodworkFlag) -> Color {
        switch flag {
        case .good:       .green
        case .borderline: .orange
        case .bad:        .red
        case .unknown:    .gray
        }
    }

    private func verdictLine(result: BloodworkEvaluation, band: BloodworkMarkerEntry.Variant.Band) -> String {
        // "ApoB 95 mg/dL — Borderline range (80–100)"
        let unit = marker.unit ?? ""
        let value = marker.value
        let range = formatRange(min: band.min, max: band.max)
        return "\(value) \(unit) sits in the \(band.label.lowercased()) range (\(range))."
    }

    private func formatRange(min: Double?, max: Double?) -> String {
        let fmt: (Double) -> String = { v in
            v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2g", v)
        }
        switch (min, max) {
        case (nil, let m?):      return "< \(fmt(m))"
        case (let m?, nil):      return "≥ \(fmt(m))"
        case (let lo?, let hi?): return "\(fmt(lo))–\(fmt(hi))"
        default:                  return "—"
        }
    }
}

// MARK: - Band position bar

private struct BandPositionBar: View {
    let variant: BloodworkMarkerEntry.Variant
    let band: BloodworkMarkerEntry.Variant.Band
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(variant.bands.indices, id: \.self) { i in
                        Rectangle()
                            .fill(color(for: variant.bands[i].status))
                            .frame(width: width(for: i, total: geo.size.width))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))

                if let position = positionFraction() {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .offset(x: max(0, geo.size.width * position - 5))
                }
            }
        }
        .frame(height: 10)
        .padding(.vertical, 2)
    }

    /// Bands tile the number line, but the outermost bands are open-ended.
    /// We replace `nil` boundaries with synthetic ones based on the inner span
    /// so the bar gets sensible relative widths.
    private func axis() -> (lo: Double, hi: Double) {
        let inner = variant.bands.compactMap { $0.min }.filter { _ in true } +
                    variant.bands.compactMap { $0.max }.filter { _ in true }
        let minInner = inner.min() ?? 0
        let maxInner = inner.max() ?? 1
        let span = max(maxInner - minInner, 1)
        let pad = span * 0.15
        return (lo: minInner - pad, hi: maxInner + pad)
    }

    private func width(for i: Int, total: CGFloat) -> CGFloat {
        let (lo, hi) = axis()
        let span = max(hi - lo, 1)
        let b = variant.bands[i]
        let low = b.min ?? lo
        let high = b.max ?? hi
        let w = CGFloat((high - low) / span) * total
        return max(2, w)
    }

    private func positionFraction() -> Double? {
        let (lo, hi) = axis()
        let span = max(hi - lo, 1)
        let clamped = min(max(value, lo), hi)
        return (clamped - lo) / span
    }

    private func color(for status: String) -> Color {
        switch status {
        case "good":       return .green.opacity(0.5)
        case "borderline": return .orange.opacity(0.5)
        case "bad":        return .red.opacity(0.5)
        default:           return .gray.opacity(0.3)
        }
    }
}

// MARK: - Edit sheet

private struct MarkerEditSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Bindable var marker: BloodworkMarker
    @Bindable var panel: BloodworkPanel

    private var unitOptions: [String] {
        guard let entry = BloodworkResearch.entry(for: marker.name) else {
            return [marker.unit].compactMap { $0 }
        }
        var options = [entry.unit.primary]
        for alt in entry.unit.alternates where !options.contains(alt.unit) {
            options.append(alt.unit)
        }
        return options
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(marker.name) {
                    TextField("Value", text: $marker.value)
                        .keyboardType(.decimalPad)
                    if unitOptions.count > 1 {
                        Picker("Unit", selection: Binding(
                            get: { marker.unit ?? unitOptions.first ?? "" },
                            set: { marker.unit = $0 }
                        )) {
                            ForEach(unitOptions, id: \.self) { Text($0).tag($0) }
                        }
                    } else if let unit = marker.unit {
                        LabeledContent("Unit", value: unit)
                    }
                }
            }
            .navigationTitle("Edit value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await services.reevaluateAndSaveBloodworkPanel(panel)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
