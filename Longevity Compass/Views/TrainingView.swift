import SwiftUI
import SwiftData

struct TrainingView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseEntry.date, order: .reverse) private var allEntries: [ExerciseEntry]
    @Query(sort: \ExerciseDef.name) private var defs: [ExerciseDef]

    @State private var showLogSheet = false
    @State private var editingEntry: ExerciseEntry?

    var body: some View {
        List {
            if allEntries.isEmpty {
                ContentUnavailableView(
                    "No exercises yet",
                    systemImage: "figure.strengthtraining.traditional",
                    description: Text("Tap \"Log Exercise\" to record your first set.")
                )
            } else {
                if !weeklyBalance.isEmpty {
                    Section("This week — sets per muscle") {
                        let maxV = weeklyBalance.map(\.sets).max() ?? 1
                        ForEach(weeklyBalance) { load in
                            MuscleBalanceBar(
                                label: load.region.displayName,
                                fraction: maxV > 0 ? load.sets / maxV : 0,
                                tint: AppTab.train.tint
                            )
                        }
                    }
                }

                ForEach(groupedEntries, id: \.key) { group in
                    Section(sectionTitle(for: group.key)) {
                        ForEach(group.value) { entry in
                            ExerciseEntryRow(
                                entry: entry,
                                photoData: defs.first(where: { $0.name == entry.exerciseName })?.photoData
                            )
                                .onTapGesture { editingEntry = entry }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        context.delete(entry)
                                        try? context.save()
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        editingEntry = entry
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
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
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AppTab.train.tint)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [.white.opacity(0.30), .clear],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.30), lineWidth: 0.8)
                    )
                    .shadow(color: AppTab.train.tint.opacity(0.35), radius: 10, x: 0, y: 4)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .sheet(isPresented: $showLogSheet) {
            LogExerciseSheet()
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                SetLoggerView(
                    exerciseName: entry.exerciseName,
                    photoData: defs.first(where: { $0.name == entry.exerciseName })?.photoData,
                    initialSets: entry.sets,
                    initialDate: entry.date
                ) { date, sets in
                    entry.date = date
                    entry.sets = sets
                    try? context.save()
                    editingEntry = nil
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingEntry = nil }
                    }
                }
            }
        }
        .task { seedIfNeeded() }
    }

    // MARK: - Weekly muscle balance

    private struct RegionLoad: Identifiable {
        let id = UUID()
        let region: MuscleRegion
        let sets: Double
    }

    /// Set-count share per muscle region over the last 7 days. Primary muscles
    /// count full, secondary count half. Set-based (not volume) so heavy
    /// compound lifts don't drown out everything else.
    private var weeklyBalance: [RegionLoad] {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        var totals: [MuscleRegion: Double] = [:]
        for entry in allEntries where entry.date >= weekAgo {
            guard let def = defs.first(where: { $0.name == entry.exerciseName }) else { continue }
            let count = Double(entry.sets.count)
            guard count > 0 else { continue }
            for m in def.primaryMuscles   { totals[m.region, default: 0] += count }
            for m in def.secondaryMuscles { totals[m.region, default: 0] += count * 0.5 }
        }
        return totals
            .sorted { $0.value > $1.value }
            .map { RegionLoad(region: $0.key, sets: $0.value) }
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
    let photoData: Data?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 5) {
                HStack {
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
                                    .glassEffect(.regular, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        if let data = photoData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: entry.exerciseSymbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
        }
    }

    private func setLabel(i: Int, set: WorkoutSet) -> String {
        let w = set.weightKg > 0 ? "\(Int(set.weightKg))kg" : "BW"
        return "\(set.reps)×\(w)"
    }
}
