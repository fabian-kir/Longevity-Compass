import SwiftUI
import SwiftData

/// Hub for Digestion Insights: status, results (unit 5), symptom log.
struct DigestionInsightsView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \SymptomEntry.onset, order: .reverse) private var symptoms: [SymptomEntry]
    @Query(sort: \DigestionTrackingPeriod.start, order: .reverse) private var periods: [DigestionTrackingPeriod]

    @State private var editing: SymptomEntry?

    private var activePeriod: DigestionTrackingPeriod? { periods.first { $0.end == nil } }

    private var symptomsByDay: [(day: Date, entries: [SymptomEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: symptoms) { cal.startOfDay(for: $0.onset) }
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { $0.onset > $1.onset })
        }
    }

    var body: some View {
        List {
            Section("Status") {
                if let period = activePeriod {
                    Text("Tracking since \(period.start.formatted(date: .abbreviated, time: .omitted))")
                    Text("\(loggedDays(in: period)) \(loggedDays(in: period) == 1 ? "day" : "days") with symptoms logged")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tracking is off. Turn it on in Settings › Data.")
                        .foregroundStyle(.secondary)
                }
            }

            // Unit 5: result sections go here, between "Status" and "Symptom log".
            Section("Results") {
                Text("Results appear once there is enough data. Analysis runs overnight while your iPhone charges.")
                    .foregroundStyle(.secondary)
            }

            Section("Symptom log") {
                if symptoms.isEmpty {
                    Text("No symptoms logged yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(symptomsByDay, id: \.day) { group in
                    Text(group.day.formatted(date: .complete, time: .omitted))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.entries) { entry in
                        Button { editing = entry } label: { row(entry) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    services.deleteSymptom(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Digestion Insights")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { entry in
            LogSymptomSheet(existing: entry)
        }
    }

    private func row(_ entry: SymptomEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind?.label ?? entry.kindRaw)
                if let level = entry.level, entry.kind?.hasLevelChoice == true {
                    Text(level.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.onset.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func loggedDays(in period: DigestionTrackingPeriod) -> Int {
        let cal = Calendar.current
        return Set(symptoms.filter { $0.onset >= period.start }.map { cal.startOfDay(for: $0.onset) }).count
    }
}
