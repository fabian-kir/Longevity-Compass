import SwiftUI

struct DigestionOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    let onStart: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("What it does") {
                    Text("Finds ingredients your symptoms tend to follow, and roughly how long after eating.")
                }
                Section("What it can't do") {
                    Label("It can't diagnose anything.", systemImage: "xmark.circle")
                    Label("It can't see effects that build up over days or weeks.", systemImage: "xmark.circle")
                    Label("It can't tell apart foods you always eat together.", systemImage: "xmark.circle")
                    Label("It doesn't replace a doctor.", systemImage: "xmark.circle")
                    Text("Results are statistics. AI meal recognition makes mistakes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("What it needs from you") {
                    Label("Log every symptom. A day without an entry counts as a good day.", systemImage: "checkmark.circle")
                    Label("Log your meals, including snacks and drinks.", systemImage: "checkmark.circle")
                    Label("Fix the meal time if you log a meal later.", systemImage: "checkmark.circle")
                    Label("Check detected allergens on meals you cooked.", systemImage: "checkmark.circle")
                    Label("Expect weeks to months, not days.", systemImage: "checkmark.circle")
                }
                Section {
                    Text("Talk to your doctor before changing your diet based on these results.")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .navigationTitle("Digestion Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onStart()
                    dismiss()
                } label: {
                    Text("Start tracking")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
    }
}
