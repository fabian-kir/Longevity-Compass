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
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            self.modelContainer = container
            self._services = State(initialValue: AppServices(context: container.mainContext))
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
