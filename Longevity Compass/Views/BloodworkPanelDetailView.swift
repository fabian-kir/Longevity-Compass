import SwiftUI

struct BloodworkPanelDetailView: View {
    @Environment(AppServices.self) private var services
    @Bindable var panel: BloodworkPanel

    var body: some View {
        Form {
            Section("Panel") {
                LabeledContent("Date", value: panel.date.formatted(date: .abbreviated, time: .omitted))
                if let lab = panel.labName, !lab.isEmpty {
                    LabeledContent("Lab", value: lab)
                }
                LabeledContent("Worst flag", value: panel.worstFlag.displayLabel)
            }

            Section("Markers") {
                ForEach(panel.markers.sorted { $0.name < $1.name }) { marker in
                    MarkerEditRow(marker: marker) {
                        Task { await services.refreshAfterEdit() }
                    }
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
    }
}

private struct MarkerEditRow: View {
    @Bindable var marker: BloodworkMarker
    let onFlagChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(marker.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(marker.value)
                if let unit = marker.unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Flag", selection: Binding(
                get: { marker.flag },
                set: { newValue in
                    marker.flag = newValue
                    onFlagChange()
                }
            )) {
                ForEach(BloodworkFlag.allCases) { flag in
                    Text(flag.displayLabel).tag(flag)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 2)
    }
}
