import SwiftUI

/// Logs a new symptom, or edits `existing` when given.
/// Common path: pick kind, pick level, tap Save (onset defaults to now).
struct LogSymptomSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var existing: SymptomEntry?

    @State private var kind: SymptomKind
    @State private var level: SymptomLevel
    @State private var onsetChoice: SymptomOnsetChoice = .now
    @State private var customOnset: Date = .now

    init(existing: SymptomEntry? = nil) {
        self.existing = existing
        let kind = existing?.kind ?? .bloating
        _kind = State(initialValue: kind)
        _level = State(initialValue: existing?.level ?? kind.levels[0])
        if let existing {
            _onsetChoice = State(initialValue: .earlier)
            _customOnset = State(initialValue: existing.onset)
        }
    }

    private var periodStart: Date {
        services.store.activeTrackingPeriod()?.start ?? .distantPast
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Symptom") {
                    Picker("Symptom", selection: $kind) {
                        ForEach(SymptomKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if kind.hasLevelChoice {
                    Section("How bad") {
                        Picker("Level", selection: $level) {
                            ForEach(kind.levels) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                Section("Started") {
                    Picker("Started", selection: $onsetChoice) {
                        ForEach(SymptomOnsetChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if onsetChoice == .earlier {
                        DatePicker(
                            "Onset",
                            selection: $customOnset,
                            in: periodStart...Date.now,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
            }
            .navigationTitle(existing == nil ? "Log symptom" : "Edit symptom")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: kind) { _, newKind in
                if !newKind.levels.contains(level) { level = newKind.levels[0] }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let now = Date.now
        let onset = onsetChoice.date(now: now, periodStart: periodStart, custom: customOnset)
        let resolvedLevel = kind.hasLevelChoice ? level : kind.levels[0]
        if let existing {
            existing.kind = kind
            existing.level = resolvedLevel
            existing.onset = onset
            services.store.saveContext()
        } else {
            services.recordSymptom(SymptomEntry(onset: onset, kind: kind, level: resolvedLevel))
        }
        dismiss()
    }
}
