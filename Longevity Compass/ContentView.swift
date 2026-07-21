import SwiftUI

struct ContentView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var bindable = services
        TabView(selection: $bindable.selectedTab) {
            NavigationStack { FocusView() }
                .tint(AppTab.focus.tint)
                .tabItem { Label("Focus", systemImage: "scope") }
                .tag(AppTab.focus)

            NavigationStack { TrainingView() }
                .tint(AppTab.train.tint)
                .tabItem { Label("Train", systemImage: "dumbbell") }
                .tag(AppTab.train)

            NavigationStack { NutritionTabView() }
                .tint(AppTab.nutrition.tint)
                .tabItem { Label("Nutrition", systemImage: "fork.knife") }
                .tag(AppTab.nutrition)

            NavigationStack { BloodworkView() }
                .tint(AppTab.bloodwork.tint)
                .tabItem { Label("Bloodwork", systemImage: "drop.fill") }
                .tag(AppTab.bloodwork)

            NavigationStack { N4x4View() }
                .tint(AppTab.n4x4.tint)
                .tabItem { Label("N4x4", systemImage: "hammer.fill") }
                .tag(AppTab.n4x4)
        }
        .tint(bindable.selectedTab.tint)
    }
}
