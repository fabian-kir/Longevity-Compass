import SwiftUI
import UIKit

/// Edit any previously logged `ManualEntry`. Exposes the date plus whichever value
/// matters for that entry type (numeric measurement, alcohol level, or boolean).
struct EditManualEntrySheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let entry: ManualEntry

    @State private var date: Date = .now
    @State private var primaryText: String = ""
    @State private var secondaryText: String = ""
    @State private var tertiaryText: String = ""
    @State private var booleanValue: Bool = false
    @State private var alcoholLevel: AlcoholLevel = .none
    @State private var notes: String = ""
    @State private var isSaving = false

    private var entryType: ManualEntryType { entry.entryType }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker(
                        "Logged at",
                        selection: $date,
                        in: ...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section(valueSectionTitle) {
                    valueFields
                }

                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || !isValid)
                }
            }
            .onAppear { load() }
        }
    }

    // MARK: - Value fields per type

    @ViewBuilder
    private var valueFields: some View {
        switch entryType {
        case .bloodPressure:
            numericRow(label: "Systolic", binding: $primaryText, unit: "mmHg", keyboard: .numberPad)
            numericRow(label: "Diastolic", binding: $secondaryText, unit: "mmHg", keyboard: .numberPad)
            numericRow(label: "Pulse", binding: $tertiaryText, unit: "bpm", keyboard: .numberPad)
        case .waist:
            numericRow(label: "Waist", binding: $primaryText, unit: "cm", keyboard: .decimalPad)
        case .bodyWeight:
            numericRow(label: "Weight", binding: $primaryText, unit: "kg", keyboard: .decimalPad)
        case .alcohol:
            Picker("Level", selection: $alcoholLevel) {
                ForEach(AlcoholLevel.allCases) { level in
                    Text(level.displayLabel).tag(level)
                }
            }
            .pickerStyle(.segmented)
        case .nicotine:
            Toggle("Used nicotine", isOn: $booleanValue)
        case .proteinHabit, .fiberHabit, .omega3Habit, .strengthTraining,
             .dentalFloss, .dentalFluoride:
            Toggle("Logged \"yes\"", isOn: $booleanValue)
        }
    }

    private func numericRow(label: String, binding: Binding<String>, unit: String, keyboard: UIKeyboardType) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("—", text: binding)
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
            Text(unit).foregroundStyle(.secondary).font(.caption)
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        switch entryType {
        case .bloodPressure:
            guard let sys = Double(primaryText), let dia = Double(secondaryText) else { return false }
            if !(60...250).contains(sys) || !(40...150).contains(dia) { return false }
            if !tertiaryText.isEmpty, Double(tertiaryText) == nil { return false }
            return true
        case .waist:
            guard let v = Double(primaryText) else { return false }
            return (30...200).contains(v)
        case .bodyWeight:
            guard let v = Double(primaryText) else { return false }
            return (20...300).contains(v)
        case .alcohol, .nicotine,
             .proteinHabit, .fiberHabit, .omega3Habit, .strengthTraining,
             .dentalFloss, .dentalFluoride:
            return true
        }
    }

    // MARK: - Labels

    private var navTitle: String {
        switch entryType {
        case .bloodPressure:    "Blood pressure"
        case .waist:            "Waist"
        case .bodyWeight:       "Body weight"
        case .proteinHabit:     "Protein hit"
        case .fiberHabit:       "Fibre hit"
        case .omega3Habit:      "Omega-3 meal"
        case .strengthTraining: "Strength session"
        case .dentalFloss:      "Floss"
        case .dentalFluoride:   "Fluoride"
        case .alcohol:          "Alcohol"
        case .nicotine:         "Nicotine"
        }
    }

    private var valueSectionTitle: String {
        switch entryType {
        case .bloodPressure: "Reading"
        case .waist, .bodyWeight: "Measurement"
        case .alcohol: "Level"
        default: "Value"
        }
    }

    // MARK: - Load / save

    private func load() {
        date = entry.date
        notes = entry.notes ?? ""
        booleanValue = entry.booleanValue ?? false
        alcoholLevel = entry.alcoholLevel ?? .none

        if let p = entry.primaryValue {
            primaryText = formatNumber(p)
        }
        if let s = entry.secondaryValue {
            secondaryText = formatNumber(s)
        }
        if let t = entry.tertiaryValue {
            tertiaryText = formatNumber(t)
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        entry.date = date

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        switch entryType {
        case .bloodPressure:
            entry.primaryValue = Double(primaryText)
            entry.secondaryValue = Double(secondaryText)
            entry.tertiaryValue = Double(tertiaryText)
        case .waist, .bodyWeight:
            entry.primaryValue = Double(primaryText)
        case .alcohol:
            entry.categoricalRaw = alcoholLevel.rawValue
        case .nicotine,
             .proteinHabit, .fiberHabit, .omega3Habit, .strengthTraining,
             .dentalFloss, .dentalFluoride:
            entry.booleanValue = booleanValue
        }

        Task {
            await services.refreshAfterEdit()
            dismiss()
        }
    }
}
