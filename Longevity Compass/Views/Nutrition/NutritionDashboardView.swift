import SwiftUI

struct NutritionDashboardView: View {
    let digest: NutritionDigest

    @AppStorage("nutrition.energyIntent") private var energyIntentRaw = EnergyIntent.maintain.rawValue
    @AppStorage("nutrition.energyGuideKcal") private var energyGuideKcal = 2_200.0
    @State private var showWeeklyDetails = false
    @State private var showEnergySettings = false

    private var energyIntent: EnergyIntent {
        EnergyIntent(rawValue: energyIntentRaw) ?? .maintain
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            dashboardHeader

            if digest.totalEntries == 0 {
                NutritionStartCard()
            } else {
                if let guidance = digest.priorityGuidance {
                    NutritionGuidanceCard(guidance: guidance)
                }
                FoodPatternCard(digest: digest)
                weeklyDetailsCard
                energyCard
            }
        }
        .sheet(isPresented: $showEnergySettings) {
            EnergyGuideSheet(
                intentRaw: $energyIntentRaw,
                dailyGuideKcal: $energyGuideKcal
            )
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your food pattern")
                    .font(.title3.weight(.bold))
                Text("Last \(digest.lookbackDays) days · \(digest.coverageDays) days logged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "leaf.fill")
                .foregroundStyle(AppTab.nutrition.tint)
                .accessibilityHidden(true)
        }
    }

    private var weeklyDetailsCard: some View {
        DisclosureGroup(isExpanded: $showWeeklyDetails) {
            VStack(alignment: .leading, spacing: 14) {
                signalSection(
                    "Add more often",
                    rollups: digest.rollups.filter { !$0.bucket.lowerIsBetter }
                )
                Divider()
                signalSection(
                    "Keep in check",
                    rollups: digest.rollups.filter(\.bucket.lowerIsBetter)
                )
            }
            .padding(.top, 12)
        } label: {
            HStack {
                Label("Weekly signals", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                let onTarget = digest.rollups.filter { $0.status == .ok }.count
                Text("\(onTarget)/\(digest.rollups.count) on track")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .glassSurface(cornerRadius: 18)
    }

    private func signalSection(_ title: String, rollups: [NutritionBucketRollup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            ForEach(rollups) { rollup in
                NutritionSignalRow(rollup: rollup)
            }
        }
    }

    private var energyCard: some View {
        Button {
            showEnergySettings = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Energy direction", systemImage: "dial.medium")
                        .font(.headline)
                    Spacer()
                    Text(energyIntent.displayLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .glassChip(tint: .blue, tintOpacity: 0.18)
                }

                if let average = digest.estimatedCaloriesPerLoggedDay {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("~\(Int(average.rounded())) kcal/day")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                            Text("Logged estimate across \(digest.energyEstimateDays) days")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(energyGuideKcal.rounded()))")
                                .font(.headline)
                                .monospacedDigit()
                            Text("daily guide")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(energyComparison(average))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                } else {
                    Text("Set a flexible daily guide for a deficit, maintenance or surplus.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "approximately")
                    Text("Directional only — photo estimates and incomplete meal logs are not precise intake measurements.")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding()
        .glassCard(tint: .blue, cornerRadius: 18, tintOpacity: 0.10)
        .accessibilityHint("Opens energy direction and daily guide settings")
    }

    private func energyComparison(_ average: Double) -> String {
        let difference = average - energyGuideKcal
        let magnitude = Int(abs(difference).rounded() / 10) * 10
        if abs(difference) < energyGuideKcal * 0.05 {
            return "Near your flexible guide"
        }
        return difference < 0
            ? "~\(magnitude) kcal below your guide"
            : "~\(magnitude) kcal above your guide"
    }
}

private struct NutritionStartCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Build a picture of how you eat", systemImage: "camera.viewfinder")
                .font(.headline)

            Text("Log ordinary meals — not just the “good” ones. After a few days, the app can spot variety, protective food groups and patterns worth rebalancing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                onboardingChip("Variety", icon: "leaf")
                onboardingChip("Food groups", icon: "square.grid.3x3")
                onboardingChip("Next meal", icon: "sparkles")
            }
        }
        .padding()
        .glassCard(tint: AppTab.nutrition.tint, cornerRadius: 18, tintOpacity: 0.14)
    }

    private func onboardingChip(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(AppTab.nutrition.tint)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 12)
    }
}

private struct NutritionGuidanceCard: View {
    let guidance: NutritionGuidance

    private var tint: Color {
        switch guidance.tone {
        case .add, .maintain: AppTab.nutrition.tint
        case .rebalance: .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                GlassIconTile(
                    systemName: guidance.systemImage,
                    tint: tint,
                    size: 46,
                    cornerRadius: 13
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(guidance.eyebrow.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(tint)
                    Text(guidance.title)
                        .font(.headline)
                    Text(guidance.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(guidance.ideas, id: \.self) { idea in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                            .foregroundStyle(tint)
                        Text(idea)
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding()
        .glassCard(tint: tint, cornerRadius: 20, tintOpacity: 0.17)
    }
}

private struct FoodPatternCard: View {
    let digest: NutritionDigest

    private var plantRollup: NutritionBucketRollup? {
        digest.rollup(for: .plantVariety)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Diet breadth", systemImage: "circle.hexagongrid.fill")
                    .font(.headline)
                Spacer()
                Text("Patterns, not grams")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                metric(
                    value: "\(Int((plantRollup?.weeklyValue ?? 0).rounded()))",
                    target: "of \(Int((plantRollup?.target ?? 30).rounded()))",
                    label: "distinct plants",
                    tint: .green
                )
                metric(
                    value: "\(digest.pattern.beneficialGroupsSeen)",
                    target: "of \(digest.pattern.beneficialGroupTarget)",
                    label: "food groups seen",
                    tint: .teal
                )
                metric(
                    value: "\(digest.pattern.mealsWithoutLimitFlags)",
                    target: "of \(digest.pattern.assessedMeals)",
                    label: "without limit flags",
                    tint: .mint
                )
            }

            Text("Food groups include vegetables, fruit, legumes, whole grains, nuts and seeds, omega-3 sources and fermented foods.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .glassCard(tint: AppTab.nutrition.tint, cornerRadius: 18, tintOpacity: 0.10)
    }

    private func metric(
        value: String,
        target: String,
        label: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                Text(target)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NutritionSignalRow: View {
    let rollup: NutritionBucketRollup

    private var progress: Double {
        guard let value = rollup.weeklyValue, rollup.target > 0 else { return 0 }
        return min(value / rollup.target, 1)
    }

    private var tint: Color {
        switch rollup.status {
        case .ok: .green
        case .veryLow, .low, .high: .orange
        case .veryHigh: .red
        case .unknown: .gray
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: rollup.bucket.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(rollup.bucket.lowerIsBetter ? .orange : AppTab.nutrition.tint)
                Text(rollup.bucket.displayLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(valueLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            ProgressView(value: progress)
                .tint(tint)
                .accessibilityLabel(rollup.bucket.displayLabel)
                .accessibilityValue(valueLabel)
        }
    }

    private var valueLabel: String {
        let value = Int((rollup.weeklyValue ?? 0).rounded())
        let target = Int(rollup.target.rounded())
        return rollup.bucket.lowerIsBetter
            ? "\(value) / ≤\(target)"
            : "\(value) / \(target)"
    }
}

private enum EnergyIntent: String, CaseIterable, Identifiable {
    case deficit
    case maintain
    case surplus

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .deficit: "Deficit"
        case .maintain: "Maintain"
        case .surplus: "Surplus"
        }
    }

    var detail: String {
        switch self {
        case .deficit: "Use the guide as a gentle ceiling, while keeping diet quality visible."
        case .maintain: "Use the guide as a flexible centreline, not a daily pass/fail score."
        case .surplus: "Use the guide as a gentle floor, while keeping food quality visible."
        }
    }
}

private struct EnergyGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var intentRaw: String
    @Binding var dailyGuideKcal: Double

    private var intent: Binding<EnergyIntent> {
        Binding(
            get: { EnergyIntent(rawValue: intentRaw) ?? .maintain },
            set: { intentRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Direction") {
                    Picker("Direction", selection: intent) {
                        ForEach(EnergyIntent.allCases) { option in
                            Text(option.displayLabel).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(intent.wrappedValue.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Stepper(value: $dailyGuideKcal, in: 1_000...5_000, step: 50) {
                        HStack {
                            Text("Daily guide")
                            Spacer()
                            Text("\(Int(dailyGuideKcal)) kcal")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("This is a user-chosen reference point. Longevity Direction intentionally treats photo-derived calories as approximate.")
                }

                Section("What stays primary") {
                    Label("Plant and food-group variety", systemImage: "leaf")
                    Label("Protective foods across the week", systemImage: "heart.text.square")
                    Label("Patterns worth adding or limiting", systemImage: "arrow.left.arrow.right")
                }
            }
            .navigationTitle("Energy guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
