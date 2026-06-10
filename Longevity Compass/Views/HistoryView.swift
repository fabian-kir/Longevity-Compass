import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \ManualEntry.date, order: .reverse) private var entries: [ManualEntry]

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No entries yet",
                    systemImage: "tray",
                    description: Text("Logged habits and entries show up here.")
                )
            } else {
                ForEach(entries) { entry in
                    HistoryRow(entry: entry)
                }
                .onDelete { offsets in
                    Task {
                        for index in offsets {
                            await services.deleteManualEntry(entries[index])
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .toolbar { EditButton() }
    }
}

private struct HistoryRow: View {
    let entry: ManualEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch entry.entryType {
        case .bloodPressure:     "heart.text.square"
        case .waist:             "ruler"
        case .bodyWeight:        "scalemass"
        case .proteinHabit:      "fork.knife"
        case .fiberHabit:        "leaf"
        case .omega3Habit:       "fish"
        case .strengthTraining:  "dumbbell"
        case .dentalFloss:       "mouth"
        case .dentalFluoride:    "drop"
        case .alcohol:           "wineglass"
        case .nicotine:          "nosign"
        }
    }

    private var label: String {
        switch entry.entryType {
        case .bloodPressure:     "Blood pressure"
        case .waist:             "Waist"
        case .bodyWeight:        "Body weight"
        case .proteinHabit:      "Protein hit"
        case .fiberHabit:        "Fibre hit"
        case .omega3Habit:       "Omega-3 meal"
        case .strengthTraining:  "Strength session"
        case .dentalFloss:       "Floss"
        case .dentalFluoride:    "Fluoride"
        case .alcohol:           "Alcohol"
        case .nicotine:          "Nicotine"
        }
    }

    private var detail: String {
        switch entry.entryType {
        case .bloodPressure:
            let sys = entry.primaryValue.map { "\(Int($0.rounded()))" } ?? "—"
            let dia = entry.secondaryValue.map { "\(Int($0.rounded()))" } ?? "—"
            let pulse = entry.tertiaryValue.map { ", pulse \(Int($0.rounded()))" } ?? ""
            return "\(sys)/\(dia) mmHg\(pulse)"
        case .waist:
            return entry.primaryValue.map { String(format: "%.1f cm", $0) } ?? "—"
        case .bodyWeight:
            return entry.primaryValue.map { String(format: "%.1f kg", $0) } ?? "—"
        case .alcohol:
            return entry.alcoholLevel?.displayLabel ?? "—"
        case .nicotine:
            return entry.booleanValue == true ? "Used" : "None"
        case .proteinHabit, .fiberHabit, .omega3Habit, .strengthTraining, .dentalFloss, .dentalFluoride:
            return entry.booleanValue == true ? "Yes" : "No"
        }
    }
}
