import SwiftUI
import SwiftData

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
                SetLoggerView(exercise: def) { date, sets in
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
    let exercise: ExerciseDef
    let onSave: (Date, [WorkoutSet]) -> Void

    @State private var sets: [WorkoutSet] = [WorkoutSet()]
    @State private var date: Date = .now

    var body: some View {
        Form {
            Section {
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    HStack(spacing: 10) {
                        Text("Set \(index + 1)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .leading)
                        TextField("0", value: $sets[index].weightKg, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("kg")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Spacer()
                        Stepper(value: $sets[index].reps, in: 1...99) {
                            Text("\(set.reps) reps")
                        }
                    }
                }
                .onDelete { sets.remove(atOffsets: $0) }

                Button {
                    var next = WorkoutSet()
                    next.weightKg = sets.last?.weightKg ?? 0
                    next.reps = sets.last?.reps ?? 1
                    sets.append(next)
                } label: {
                    Label("Add Set", systemImage: "plus")
                }
            } header: {
                Text("Sets — swipe left to delete")
            }

            Section("Date & Time") {
                DatePicker(
                    "Logged at",
                    selection: $date,
                    in: ...Date.now,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(date, sets) }
                    .disabled(sets.isEmpty)
            }
        }
    }
}
