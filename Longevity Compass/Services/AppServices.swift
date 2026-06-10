import Foundation
import SwiftData

enum AppTab: Hashable {
    case focus
    case track
    case train
    case nutrition
    case trends
    case data
}

@Observable
final class AppServices {
    let store: LocalDataStore
    let healthKit: HealthKitManager
    let notifications: NotificationManager
    let openRouter: OpenRouterClient

    private(set) var healthSnapshot: HealthKitSnapshot = HealthKitSnapshot()
    private(set) var currentResult: PriorityEngine.Result?
    private(set) var nutritionDigest: NutritionDigest?
    private(set) var isRefreshing: Bool = false
    private(set) var hasBootstrapped: Bool = false

    /// Cross-view navigation hint. Views observe this and update their TabView selection.
    var selectedTab: AppTab = .focus

    init(context: ModelContext) {
        self.store = LocalDataStore(context: context)
        self.healthKit = HealthKitManager()
        self.notifications = NotificationManager()
        self.openRouter = OpenRouterClient()
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await healthKit.requestAuthorization()
        await notifications.requestAuthorization()
        await refresh()
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        healthSnapshot = await healthKit.refreshSnapshot()
        let entries = store.fetchAllManualEntries()
        let nutrition = store.fetchAllNutritionEntries()
        nutritionDigest = NutritionEngine.digest(nutrition)

        let result = PriorityEngine.evaluate(
            manualEntries: entries,
            nutritionEntries: nutrition,
            healthSnapshot: healthSnapshot
        )
        currentResult = result
        store.recordPriorityHistory(result.allItems)
        await notifications.scheduleReminders(for: result, manualEntries: entries)
    }

    func recordManualEntry(_ entry: ManualEntry) async {
        store.insertManualEntry(entry)
        await refresh()
    }

    func recordNutritionEntry(_ entry: NutritionEntry) async {
        store.insertNutritionEntry(entry)
        await refresh()
    }

    func deleteNutritionEntry(_ entry: NutritionEntry) async {
        store.deleteNutritionEntry(entry)
        await refresh()
    }

    func logBloodPressure(systolic: Double, diastolic: Double, date: Date) async throws {
        try await healthKit.saveBloodPressure(systolic: systolic, diastolic: diastolic, date: date)
        await refresh()
    }

    func deleteManualEntry(_ entry: ManualEntry) async {
        store.deleteManualEntry(entry)
        await refresh()
    }

    func deleteAllLocalData() async {
        store.deleteAllLocalData()
        notifications.cancelAll()
        await refresh()
    }
}
