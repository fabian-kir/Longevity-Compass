import SwiftUI

/// One row in the Track tab. In-app trackable items expand inline for logging.
/// Health-backed items show an "Open Health" button.
struct TrackingCardView: View {
    let card: TrackingCard
    @Binding var expandedDomain: HealthDomain?
    let todaysEntries: [ManualEntry]
    let onMeasureBP: () -> Void
    let onLogNicotine: (Bool) -> Void
    let onLogAlcohol: (AlcoholLevel) -> Void
    let onLogDentalFloss: () -> Void
    let onLogDentalFluoride: () -> Void
    let onOpenHealth: () -> Void

    private var domain: HealthDomain { card.item.domain }
    private var isExpanded: Bool { expandedDomain == domain }
    private var actionType: TrackActionType { TrackingRecommendationEngine.actionType(for: domain) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if !card.contextLine.isEmpty {
                Text(card.contextLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if isExpanded {
                inlineControls
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: card.item.systemImageName)
                .foregroundStyle(urgencyColor)
                .frame(width: 22)
            Text(card.item.title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if card.urgency == .onTrack && !isExpanded {
                onTrackBadge
            } else {
                primaryActionButton
            }
        }
    }

    // MARK: - Primary action button (shown for Track Now / Coming Up, and expanded onTrack rows)

    @ViewBuilder
    private var primaryActionButton: some View {
        switch actionType {
        case .bloodPressure:
            Button("Measure") { onMeasureBP() }
                .buttonStyle(TrackPillButtonStyle(tint: urgencyColor))
        case .openHealth:
            Button("Open Health") { onOpenHealth() }
                .buttonStyle(TrackPillButtonStyle(tint: .secondary))
        case .nicotine, .alcohol, .dental:
            Button(isExpanded ? "Done" : "Log today") {
                withAnimation(.spring(duration: 0.25)) {
                    expandedDomain = isExpanded ? nil : domain
                }
            }
            .buttonStyle(TrackPillButtonStyle(tint: isExpanded ? Color(.secondaryLabel) : urgencyColor))
        }
    }

    // MARK: - On-track compact badge

    @ViewBuilder
    private var onTrackBadge: some View {
        if actionType == .openHealth {
            // Non-tappable — nothing useful to expand for auto-tracked metrics in good state.
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.caption)
                Text(nextDueLabel).font(.caption)
            }
            .foregroundStyle(.secondary)
        } else {
            // Tappable — expands to show in-app log controls on demand.
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    expandedDomain = isExpanded ? nil : domain
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption)
                    Text(nextDueLabel).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var nextDueLabel: String {
        guard let days = card.dueInDays else { return "On track" }
        if days <= 0  { return "Due now" }
        if days == 1  { return "Due tomorrow" }
        return "Next in \(days)d"
    }

    // MARK: - Inline controls (shown when expanded)

    @ViewBuilder
    private var inlineControls: some View {
        switch actionType {
        case .nicotine:   nicotineControls
        case .alcohol:    alcoholControls
        case .dental:     dentalControls
        case .bloodPressure, .openHealth: EmptyView()
        }
    }

    private var nicotineControls: some View {
        let usedToday      = hasTodayEntry(type: .nicotine, value: true)
        let abstainedToday = hasTodayEntry(type: .nicotine, value: false)
        return HStack(spacing: 8) {
            pillButton(title: "None", filled: abstainedToday, tint: .green)  { onLogNicotine(false) }
            pillButton(title: "Used", filled: usedToday,      tint: .red)    { onLogNicotine(true)  }
        }
    }

    private var alcoholControls: some View {
        let current = todaysAlcoholLevel()
        return HStack(spacing: 8) {
            ForEach(AlcoholLevel.allCases) { level in
                pillButton(title: level.displayLabel, filled: current == level, tint: alcoholTint(level)) {
                    onLogAlcohol(level)
                }
            }
        }
    }

    private var dentalControls: some View {
        let flossedToday  = hasTodayEntry(type: .dentalFloss,    value: true)
        let fluorideToday = hasTodayEntry(type: .dentalFluoride, value: true)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Flossed", systemImage: "mouth").font(.subheadline)
                Spacer()
                pillButton(title: flossedToday ? "Logged ✓" : "Log", filled: flossedToday, tint: .green) {
                    onLogDentalFloss()
                }
            }
            HStack {
                Label("Fluoride gel", systemImage: "drop").font(.subheadline)
                Spacer()
                pillButton(title: fluorideToday ? "Logged ✓" : "Log", filled: fluorideToday, tint: .green) {
                    onLogDentalFluoride()
                }
            }
        }
    }

    // MARK: - Helpers

    private func hasTodayEntry(type: ManualEntryType, value: Bool) -> Bool {
        let start = Calendar.current.startOfDay(for: .now)
        return todaysEntries.contains { $0.entryType == type && $0.date >= start && $0.booleanValue == value }
    }

    private func todaysAlcoholLevel() -> AlcoholLevel? {
        let start = Calendar.current.startOfDay(for: .now)
        return todaysEntries
            .filter { $0.entryType == .alcohol && $0.date >= start }
            .sorted { $0.date > $1.date }
            .first?.alcoholLevel
    }

    private var urgencyColor: Color {
        switch card.urgency {
        case .trackNow:   card.item.status == .urgent ? .red : .orange
        case .comingSoon: .yellow
        case .onTrack:    .green
        }
    }

    private func pillButton(title: String, filled: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(filled ? tint.opacity(0.25) : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(filled ? tint : .primary)
        }
        .buttonStyle(.plain)
    }

    private func alcoholTint(_ level: AlcoholLevel) -> Color {
        switch level {
        case .none:  .green
        case .light: .yellow
        case .heavy: .red
        }
    }
}

// MARK: - Shared pill button style (used for header action buttons)

struct TrackPillButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.35 : 0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
