import Foundation
import SwiftData

@Observable
final class LocalDataStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Manual entries

    func insertManualEntry(_ entry: ManualEntry) {
        context.insert(entry)
        try? context.save()
    }

    func fetchAllManualEntries() -> [ManualEntry] {
        let descriptor = FetchDescriptor<ManualEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteManualEntry(_ entry: ManualEntry) {
        context.delete(entry)
        try? context.save()
    }

    // MARK: - Snapshots

    func insertSnapshot(_ snapshot: HealthMetricSnapshot) {
        context.insert(snapshot)
        try? context.save()
    }

    func fetchAllSnapshots() -> [HealthMetricSnapshot] {
        let descriptor = FetchDescriptor<HealthMetricSnapshot>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Priority history

    func recordPriorityHistory(_ items: [PriorityItem], generatedAt: Date = .now) {
        for item in items {
            let entry = PriorityHistoryEntry(
                generatedAt: generatedAt,
                domain: item.domain,
                status: item.status,
                trend: item.trend,
                priorityScore: item.priorityScore,
                reason: item.reason
            )
            context.insert(entry)
        }
        try? context.save()
    }

    func fetchPriorityHistory() -> [PriorityHistoryEntry] {
        let descriptor = FetchDescriptor<PriorityHistoryEntry>(
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Nutrition entries

    func insertNutritionEntry(_ entry: NutritionEntry) {
        context.insert(entry)
        try? context.save()
    }

    func fetchAllNutritionEntries() -> [NutritionEntry] {
        let descriptor = FetchDescriptor<NutritionEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteNutritionEntry(_ entry: NutritionEntry) {
        context.delete(entry)
        try? context.save()
    }

    // MARK: - Bloodwork

    func insertBloodworkPanel(_ panel: BloodworkPanel) {
        context.insert(panel)
        try? context.save()
    }

    func fetchAllBloodworkPanels() -> [BloodworkPanel] {
        let descriptor = FetchDescriptor<BloodworkPanel>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteBloodworkPanel(_ panel: BloodworkPanel) {
        context.delete(panel)
        try? context.save()
    }

    // MARK: - Exercise

    func fetchAllExerciseDefs() -> [ExerciseDef] {
        let descriptor = FetchDescriptor<ExerciseDef>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchAllExerciseEntries() -> [ExerciseEntry] {
        let descriptor = FetchDescriptor<ExerciseEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func saveContext() {
        try? context.save()
    }

    // MARK: - Wipe

    func deleteAllLocalData() {
        for e in fetchAllManualEntries()      { context.delete(e) }
        for s in fetchAllSnapshots()          { context.delete(s) }
        for p in fetchPriorityHistory()       { context.delete(p) }
        for n in fetchAllNutritionEntries()   { context.delete(n) }
        for d in fetchAll(ExerciseDef.self)   { context.delete(d) }
        for e in fetchAll(ExerciseEntry.self) { context.delete(e) }
        for b in fetchAllBloodworkPanels()    { context.delete(b) }
        try? context.save()
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }
}
