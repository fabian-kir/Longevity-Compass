import SwiftUI

struct BloodworkMarkerGuideView: View {
    var body: some View {
        Form {
            Section {
                Text("A short guide to deciding what to ask for on a blood panel. Core markers carry the most signal per dollar; extended ones add useful context; specialized ones are only worth ordering with a specific reason.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(BloodworkMarkerCatalog.Tier.allCases) { tier in
                Section {
                    ForEach(BloodworkMarkerCatalog.suggestions(for: tier)) { suggestion in
                        MarkerGuideRow(suggestion: suggestion)
                    }
                } header: {
                    HStack {
                        Text(tier.title)
                        Spacer()
                        tierBadge(tier)
                    }
                } footer: {
                    Text(tier.subtitle)
                }
            }
        }
        .navigationTitle("Marker guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func tierBadge(_ tier: BloodworkMarkerCatalog.Tier) -> some View {
        Text(tier == .core ? "MUST" : tier == .extended ? "NICE" : "OPTIONAL")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tierTint(tier).opacity(0.18), in: Capsule())
            .foregroundStyle(tierTint(tier))
    }

    private func tierTint(_ tier: BloodworkMarkerCatalog.Tier) -> Color {
        switch tier {
        case .core:        .red
        case .extended:    .orange
        case .specialized: .gray
        }
    }
}

private struct MarkerGuideRow: View {
    let suggestion: BloodworkMarkerCatalog.Suggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(suggestion.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(suggestion.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(suggestion.detail)
                .font(.footnote)
                .foregroundStyle(.primary)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}
