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
            BloodworkPanel.self,
            BloodworkMarker.self,
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

        // TODO: Wire `BioAgeProfileTests.runAll()` here under #if DEBUG once
        // the Profile A delta range is reconciled with the engine (see notes
        // in BioAgeProfileTests.swift). Currently calling it crashes the app
        // at launch because Profile A's delta lands ~0.25y outside the spec's
        // expected range — the harness is intentionally manual-run for now.
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
