import IntervalEngine
import SwiftUI
import SwiftData

@main
struct Longevity_CompassApp: App {
    let modelContainer: ModelContainer
    @State private var services: AppServices

    init() {
        let schema = Schema([
            ManualEntry.self,
            HealthMetricSnapshot.self,
            PriorityHistoryEntry.self,
            NutritionEntry.self,
            ExerciseDef.self,
            ExerciseEntry.self,
            N4x4WorkoutLog.self,
            BloodworkPanel.self,
            BloodworkMarker.self,
            SymptomEntry.self,
            DigestionTrackingPeriod.self,
            DigestionAnalysisRun.self,
        ])
        var inMemory = false
        #if DEBUG
        inMemory = MockMode.isActive
        #endif
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            self.modelContainer = container
            #if DEBUG
            if MockMode.isActive { MockData.seed(into: container.mainContext) }
            #endif
            let services = AppServices(context: container.mainContext)
            self._services = State(initialValue: services)
            DigestionBackgroundTask.register(services: services)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services)
                .task { await services.bootstrap() }
        }
        .modelContainer(modelContainer)
    }
}
