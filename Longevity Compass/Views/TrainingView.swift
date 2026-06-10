import SwiftUI
import SwiftData

struct TrainingView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseEntry.date, order: .reverse) private var allEntries: [ExerciseEntry]
    @Query(sort: \ExerciseDef.sortOrder) private var defs: [ExerciseDef]

    @State private var showLogSheet = false

    var body: some View {
        List {
            if allEntries.isEmpty {
                ContentUnavailableView(
                    "No exercises yet",
                    systemImage: "figure.strengthtraining.traditional",
                    description: Text("Tap \"Log Exercise\" to record your first set.")
                )
            } else {
                ForEach(groupedEntries, id: \.key) { group in
                    Section(sectionTitle(for: group.key)) {
                        ForEach(group.value) { entry in
                            ExerciseEntryRow(entry: entry)
                        }
                        .onDelete { offsets in
                            for i in offsets { context.delete(group.value[i]) }
                            try? context.save()
                        }
                    }
                }
            }
        }
        .navigationTitle("Train")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ExerciseLibraryView()
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Manage exercises")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { showLogSheet = true } label: {
                Label("Log Exercise", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .sheet(isPresented: $showLogSheet) {
            LogExerciseSheet()
        }
        .task { seedIfNeeded() }
    }

    // MARK: - Grouping

    private var groupedEntries: [(key: Date, value: [ExerciseEntry])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: allEntries) { cal.startOfDay(for: $0.date) }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (key: $0.key, value: $0.value.sorted { $0.date > $1.date }) }
    }

    private func sectionTitle(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Seed

    private func seedIfNeeded() {
        guard defs.isEmpty else { return }
        let defaults: [(String, String)] = [
            ("Squat",           "figure.strengthtraining.traditional"),
            ("Bench Press",     "dumbbell.fill"),
            ("Deadlift",        "figure.strengthtraining.functional"),
            ("Pull-up",         "figure.gymnastics"),
            ("Overhead Press",  "figure.strengthtraining.traditional"),
        ]
        for (i, (name, symbol)) in defaults.enumerated() {
            context.insert(ExerciseDef(name: name, sfSymbol: symbol, sortOrder: i))
        }
        try? context.save()
    }
}

// MARK: - Entry Row

struct ExerciseEntryRow: View {
    let entry: ExerciseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: entry.exerciseSymbol)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(entry.exerciseName)
                    .font(.headline)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.sets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(entry.sets.enumerated()), id: \.element.id) { i, set in
                            Text(setLabel(i: i, set: set))
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func setLabel(i: Int, set: WorkoutSet) -> String {
        let w = set.weightKg > 0 ? "\(Int(set.weightKg))kg" : "BW"
        return "\(set.reps)×\(w)"
    }
}
