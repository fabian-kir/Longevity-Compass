import SwiftUI

struct IntakeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var preferences = IntakePreferences()

    init() {}

    private var goal: Binding<EnergyGoal> {
        Binding(
            get: { preferences.energyGoal },
            set: { preferences.energyGoalRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WholeNumberFieldRow(title: "Daily target", unit: "kcal", placeholder: "Off", value: preferences.$calorieTarget)
                    if preferences.calorieTarget > 0 {
                        Picker("Goal", selection: goal) {
                            ForEach(EnergyGoal.allCases) { option in
                                Text(option.displayLabel).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Calories")
                } footer: {
                    if preferences.calorieTarget > 0 {
                        Text(preferences.energyGoal.detail)
                    } else {
                        Text("Leave empty to track calories without a target.")
                    }
                }

                Section {
                    WholeNumberFieldRow(title: "Protein", unit: "g", placeholder: "Off", value: preferences.$proteinTarget)
                    WholeNumberFieldRow(title: "Carbs", unit: "g", placeholder: "Off", value: preferences.$carbsTarget)
                    WholeNumberFieldRow(title: "Fat", unit: "g", placeholder: "Off", value: preferences.$fatTarget)
                    WholeNumberFieldRow(title: "Fibre", unit: "g", placeholder: "Off", value: preferences.$fiberTarget)
                } header: {
                    Text("Macros & fibre per day")
                } footer: {
                    Text("Leave a field empty to track without a target. Protein and fibre count as minimums, carbs and fat as limits.")
                }

                Section {
                    NavigationLink {
                        IntakeWindowSettingsView()
                    } label: {
                        LabeledContent("Tracking window", value: windowSummary)
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Add up intake over several days instead of one, for example with intermittent fasting.")
                }

                Section {
                    Label("Photo meals use AI estimates scaled to the weight you confirm.", systemImage: "camera")
                    Label("Barcode products use Open Food Facts values.", systemImage: "barcode.viewfinder")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Intake targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var windowSummary: String {
        let length = preferences.windowLength
        switch preferences.windowMode {
        case .daily:   return "Daily"
        case .fixed:   return "\(length)-day blocks"
        case .rolling: return "Rolling \(length) days"
        }
    }
}

private struct IntakeWindowSettingsView: View {
    private var preferences = IntakePreferences()

    init() {}

    private var mode: Binding<IntakeWindowMode> {
        Binding(
            get: { preferences.windowMode },
            set: { newMode in
                preferences.windowModeRaw = newMode.rawValue
                // A fresh fixed window starts its first block today.
                if newMode == .fixed && preferences.windowAnchor == 0 {
                    preferences.windowAnchor = Calendar.current.startOfDay(for: .now).timeIntervalSinceReferenceDate
                }
            }
        )
    }

    private var anchor: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSinceReferenceDate: preferences.windowAnchor) },
            set: { preferences.windowAnchor = Calendar.current.startOfDay(for: $0).timeIntervalSinceReferenceDate }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Window", selection: mode) {
                    ForEach(IntakeWindowMode.allCases) { option in
                        Text(option.displayLabel).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(modeExplanation)
            }

            if preferences.windowMode != .daily {
                Section {
                    Stepper(value: preferences.$windowLength, in: IntakeSettings.windowLengthRange) {
                        LabeledContent("Length", value: "\(preferences.windowLength) days")
                    }
                    if preferences.windowMode == .fixed {
                        DatePicker("A block starts on", selection: anchor, displayedComponents: .date)
                    }
                } footer: {
                    Text(budgetExplanation)
                }
            }
        }
        .navigationTitle("Tracking window")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modeExplanation: String {
        let length = preferences.windowLength
        switch preferences.windowMode {
        case .daily:
            return "Each calendar day starts from zero."
        case .fixed:
            return "Intake adds up over blocks of \(length) days, then resets. Suits a fixed schedule such as 5:2 or alternate-day fasting: a fasting day leaves room for the next."
        case .rolling:
            return "Counts the last \(length) days including today, with no hard reset. Each midnight the oldest day drops out, so a big day weighs on the next \(length - 1)."
        }
    }

    private var budgetExplanation: String {
        let length = preferences.windowLength
        let target = preferences.calorieTarget
        guard target > 0 else {
            return "Daily targets are multiplied by \(length) for the window."
        }
        let total = Int((target * Double(length)).rounded()).formatted()
        return "Daily targets are multiplied by \(length): \(Int(target.rounded()).formatted()) kcal/day becomes \(total) kcal per window."
    }
}
