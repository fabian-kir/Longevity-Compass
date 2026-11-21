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
            sortBy: [SortDescriptor(\.name)]
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

    // MARK: - N4x4 workouts

    func fetchAllN4x4WorkoutLogs() -> [N4x4WorkoutLog] {
        let descriptor = FetchDescriptor<N4x4WorkoutLog>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteN4x4WorkoutLog(_ log: N4x4WorkoutLog) {
        context.delete(log)
        try? context.save()
    }

    // MARK: - Digestion Insights

    func insertSymptom(_ entry: SymptomEntry) {
        context.insert(entry)
        try? context.save()
    }

    func fetchAllSymptoms() -> [SymptomEntry] {
        let descriptor = FetchDescriptor<SymptomEntry>(
            sortBy: [SortDescriptor(\.onset, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteSymptom(_ entry: SymptomEntry) {
        context.delete(entry)
        try? context.save()
    }

    func fetchTrackingPeriods() -> [DigestionTrackingPeriod] {
        let descriptor = FetchDescriptor<DigestionTrackingPeriod>(
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func activeTrackingPeriod() -> DigestionTrackingPeriod? {
        fetchTrackingPeriods().first { $0.end == nil }
    }

    /// Starts a new period. Returns the existing one if tracking is already active.
    @discardableResult
    func startTracking(at start: Date = .now) -> DigestionTrackingPeriod {
        if let active = activeTrackingPeriod() { return active }
        let period = DigestionTrackingPeriod(start: start)
        context.insert(period)
        try? context.save()
        return period
    }

    func stopTracking(at end: Date = .now) {
        guard let active = activeTrackingPeriod() else { return }
        active.end = max(end, active.start)
        try? context.save()
    }

    func insertAnalysisRun(_ run: DigestionAnalysisRun) {
        context.insert(run)
        try? context.save()
    }

    /// Newest first.
    func fetchAnalysisRuns() -> [DigestionAnalysisRun] {
        let descriptor = FetchDescriptor<DigestionAnalysisRun>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func deleteAnalysisRun(_ run: DigestionAnalysisRun) {
        context.delete(run)
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
        for n in fetchAll(N4x4WorkoutLog.self) { context.delete(n) }
        for b in fetchAllBloodworkPanels()    { context.delete(b) }
        for s in fetchAllSymptoms()           { context.delete(s) }
        for p in fetchTrackingPeriods()       { context.delete(p) }
        for r in fetchAnalysisRuns()          { context.delete(r) }
        try? context.save()
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }
}
