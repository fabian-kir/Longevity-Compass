import SwiftUI

/// Plain-language method page (B14 point 5). The full methodology lives in
/// docs/digestion-insights-methodology.md.
struct DigestionHowItWorksView: View {
    var body: some View {
        List {
            Section("What gets compared") {
                Text("For every ingredient, allergen and food group in your meals, the app compares how often symptoms start in the hours after eating it with how often they start at other times. Days with logged meals and no symptom count as good days; days without any logged meal are left out.")
            }
            Section("The delay curve") {
                Text("Symptoms can follow a food after one hour or after two days. Instead of fixed time windows, the app estimates a smooth curve: how much more (or less) often symptoms start 0 to 96 hours after eating. The median delay is the time by which half of the extra symptoms have started.")
            }
            Section("Confidence") {
                Text("The analysis is Bayesian. Confidence is the estimated chance that a food makes symptoms more frequent. A clear pattern needs high confidence in the whole log and in each half of it separately. \"No link found\" means the data rule out a noticeable effect; it does not mean a food is safe. Results are only shown when the calculation passed all of its checks.")
            }
            Section("Why it takes weeks to months") {
                Text("Most foods are eaten with other foods, and symptoms have many causes. Telling a real pattern from chance needs many meals and many symptom-free days. In simulations, even strong effects often took months to show up, and effects that start within a few hours of eating were often missed. Results get more reliable the longer you log.")
            }
            Section("AI versus declared data") {
                Text("Allergens declared on Open Food Facts labels, or set by you, count fully. Complete ingredient lists count almost fully. Allergens and ingredients the AI sees in a meal photo, \"may contain\" traces and incomplete ingredient lists count half, because AI meal recognition makes mistakes.")
            }
            Section("Limits") {
                Label("It finds patterns; it does not diagnose anything or name a cause.", systemImage: "info.circle")
                Label("Effects that build up over more than 96 hours are not covered.", systemImage: "info.circle")
                Label("Foods you always eat together can't be told apart.", systemImage: "info.circle")
                Label("Results are statistics, not medical data.", systemImage: "info.circle")
                Text("Talk to your doctor before changing your diet based on these results.")
                    .font(.subheadline.weight(.semibold))
            }
            Section {
                Link(destination: DigestionPresentation.methodologyURL) {
                    Label("Full methodology", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("How this works")
        .navigationBarTitleDisplayMode(.inline)
    }
}
