import SwiftUI
import SwiftData
import Charts

struct LogExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseDef.sortOrder) private var exercises: [ExerciseDef]

    var body: some View {
        NavigationStack {
            List(exercises) { exercise in
                NavigationLink(value: exercise) {
                    ExerciseDefRow(def: exercise)
                }
            }
            .navigationTitle("Log Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ExerciseDef.self) { def in
                SetLoggerView(exerciseName: def.name) { date, sets in
                    let entry = ExerciseEntry(date: date, name: def.name, symbol: def.sfSymbol, sets: sets)
                    context.insert(entry)
                    try? context.save()
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if exercises.isEmpty {
                    ContentUnavailableView(
                        "No exercises",
                        systemImage: "dumbbell",
                        description: Text("Add exercises in the library first.")
                    )
                }
            }
        }
    }
}

// MARK: - Set Logger

struct SetLoggerView: View {
    let exerciseName: String
    let onSave: (Date, [WorkoutSet]) -> Void

    @State private var sets: [WorkoutSet]
    @State private var date: Date
    @State private var selectedSetID: UUID?
    @State private var pickerWeightKg: Double = 0
    @State private var pickerReps: Int = 1

    @Query private var history: [ExerciseEntry]
    private let initialDate: Date

    // 0–29.5 kg in 0.5 steps, then 30–300 kg in 5 steps
    private static let weightValues: [Double] =
        stride(from: 0.0, through: 29.5, by: 0.5).map { $0 } +
        stride(from: 30.0, through: 300.0, by: 5.0).map { $0 }

    init(exerciseName: String, initialSets: [WorkoutSet] = [], initialDate: Date = .now, onSave: @escaping (Date, [WorkoutSet]) -> Void) {
        self.exerciseName = exerciseName
        self.initialDate = initialDate
        self.onSave = onSave
        let s = initialSets.isEmpty ? [WorkoutSet()] : initialSets
        _sets = State(initialValue: s)
        _date = State(initialValue: initialDate)
        if let last = s.last {
            _selectedSetID = State(initialValue: last.id)
            _pickerWeightKg = State(initialValue: Self.snap(last.weightKg))
            _pickerReps = State(initialValue: last.reps)
        }
        let name = exerciseName
        _history = Query(
            filter: #Predicate<ExerciseEntry> { $0.exerciseName == name },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    private var selectedIndex: Int? {
        sets.firstIndex(where: { $0.id == selectedSetID })
    }

    // Past sessions = history minus the entry currently being edited (matched by exact date)
    private var pastSessions: [ExerciseEntry] {
        history.filter { abs($0.date.timeIntervalSince(initialDate)) > 1 }
    }

    /// Running average of weight and reps for the given set index, over up to 3 most recent sessions.
    /// Returns nil if no past session had a set at this position.
    private func target(forSetIndex i: Int) -> (weight: Double, reps: Int)? {
        let recent = pastSessions.prefix(3)
        let relevantSets: [WorkoutSet] = recent.compactMap { entry in
            let s = entry.sets
            return i < s.count ? s[i] : nil
        }
        guard !relevantSets.isEmpty else { return nil }
        let avgW = relevantSets.map(\.weightKg).reduce(0, +) / Double(relevantSets.count)
        let avgR = Double(relevantSets.map(\.reps).reduce(0, +)) / Double(relevantSets.count)
        return (Self.snap(avgW), max(1, min(50, Int(avgR.rounded()))))
    }

    private var selectedTarget: (weight: Double, reps: Int)? {
        guard let idx = selectedIndex else { return nil }
        return target(forSetIndex: idx)
    }

    private var currentVolume: Double {
        sets.reduce(0) { $0 + $1.weightKg * Double($1.reps) }
    }

    private struct VolumePoint: Identifiable {
        let id = UUID()
        let date: Date
        let volume: Double
        let isCurrent: Bool
    }

    private var volumeChartData: [VolumePoint] {
        var data = pastSessions.prefix(10).reversed().map { entry in
            let v = entry.sets.reduce(0) { $0 + $1.weightKg * Double($1.reps) }
            return VolumePoint(date: entry.date, volume: v, isCurrent: false)
        }
        data.append(VolumePoint(date: date, volume: currentVolume, isCurrent: true))
        return data
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    Button {
                        selectSet(at: index)
                    } label: {
                        HStack {
                            Text("Set \(index + 1)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .leading)
                            Spacer()
                            Text(weightLabel(set.weightKg))
                                .font(.subheadline)
                            Text("·")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)
                            Text("\(set.reps) reps")
                                .font(.subheadline)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(set.id == selectedSetID ? Color.accentColor : .clear)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(set.id == selectedSetID ? Color.accentColor.opacity(0.08) : nil)
                }
                .onDelete { sets.remove(atOffsets: $0) }

                Button {
                    var next = WorkoutSet()
                    next.weightKg = pickerWeightKg
                    next.reps = pickerReps
                    sets.append(next)
                    selectSet(at: sets.count - 1)
                } label: {
                    Label("Add Set", systemImage: "plus")
                }
            } header: {
                Text("Sets — swipe left to delete")
            }

            if let idx = selectedIndex {
                Section {
                    HStack(spacing: 0) {
                        Picker("weight", selection: $pickerWeightKg) {
                            ForEach(Self.weightValues, id: \.self) { w in
                                weightPickerLabel(w, isTarget: selectedTarget?.weight == w)
                                    .tag(w)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 110)
                        .clipped()
                        .onChange(of: pickerWeightKg) { _, _ in updateSelectedSet() }

                        Text("kg")
                            .font(.body.weight(.semibold))
                            .padding(.leading, 6)

                        Spacer()

                        Picker("reps", selection: $pickerReps) {
                            ForEach(1...50, id: \.self) { r in
                                repsPickerLabel(r, isTarget: selectedTarget?.reps == r)
                                    .tag(r)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 72)
                        .clipped()
                        .onChange(of: pickerReps) { _, _ in updateSelectedSet() }

                        Text("reps")
                            .font(.body.weight(.semibold))
                            .padding(.leading, 6)
                    }
                    .frame(height: 150)
                } header: {
                    Text("Set \(idx + 1)")
                }
            }

            Section("Date & Time") {
                DatePicker(
                    "Logged at",
                    selection: $date,
                    in: ...Date.now,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            if !pastSessions.isEmpty {
                Section("Volume per session") {
                    Chart(volumeChartData) { point in
                        BarMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Volume", point.volume)
                        )
                        .foregroundStyle(point.isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                        .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 140)
                }
            }
        }
        .navigationTitle(exerciseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(date, sets) }
                    .disabled(sets.isEmpty)
            }
        }
    }

    private func weightPickerLabel(_ w: Double, isTarget: Bool) -> Text {
        let s = w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))" : String(format: "%.1f", w)
        if isTarget {
            return Text("\(Image(systemName: "target"))  \(s)").foregroundColor(.accentColor)
        }
        return Text(s)
    }

    private func repsPickerLabel(_ r: Int, isTarget: Bool) -> Text {
        if isTarget {
            return Text("\(Image(systemName: "target"))  \(r)").foregroundColor(.accentColor)
        }
        return Text("\(r)")
    }

    private func selectSet(at index: Int) {
        selectedSetID = sets[index].id
        pickerWeightKg = Self.snap(sets[index].weightKg)
        pickerReps = sets[index].reps
    }

    private func updateSelectedSet() {
        guard let i = selectedIndex else { return }
        sets[i].weightKg = pickerWeightKg
        sets[i].reps = pickerReps
    }

    private static func snap(_ kg: Double) -> Double {
        weightValues.min(by: { abs($0 - kg) < abs($1 - kg) }) ?? 0
    }

    private func weightLabel(_ kg: Double) -> String {
        if kg == 0 { return "BW" }
        return kg.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(kg)) kg"
            : String(format: "%.1f kg", kg)
    }
}
