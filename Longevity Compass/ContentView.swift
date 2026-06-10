import SwiftUI

struct ContentView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var bindable = services
        TabView(selection: $bindable.selectedTab) {
            NavigationStack { FocusView() }
                .tabItem { Label("Focus", systemImage: "scope") }
                .tag(AppTab.focus)

            NavigationStack { TrackView() }
                .tabItem { Label("Track", systemImage: "square.and.pencil") }
                .tag(AppTab.track)

            NavigationStack { TrainingView() }
                .tabItem { Label("Train", systemImage: "dumbbell") }
                .tag(AppTab.train)

            NavigationStack { NutritionTabView() }
                .tabItem { Label("Nutrition", systemImage: "fork.knife") }
                .tag(AppTab.nutrition)

            NavigationStack { TrendsView() }
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(AppTab.trends)

            NavigationStack { DataExportView() }
                .tabItem { Label("Data", systemImage: "externaldrive") }
                .tag(AppTab.data)
        }
    }
}
