import SwiftUI

/// One row in the Track tab. In-app trackable items expand inline for logging.
/// Health-backed items show an "Open Health" button.
struct TrackingCardView: View {
    let card: TrackingCard
    @Binding var expandedDomain: HealthDomain?
    let todaysEntries: [ManualEntry]
    let latestBP: BloodPressureReading?
    let onLogBP: (Double, Double) -> Void
    let onOpenBPSheet: () -> Void
    let onLogNicotine: (Bool) -> Void
    let onLogAlcohol: (AlcoholLevel) -> Void
    let onLogDentalFloss: () -> Void
    let onLogDentalFluoride: () -> Void
    let onOpenHealth: () -> Void
    let onOpenBloodwork: () -> Void
    let onOpenTrain: () -> Void

    @State private var bpSystolicText: String = ""
    @State private var bpDiastolicText: String = ""
    @FocusState private var bpFocus: BPField?

    private enum BPField { case systolic, diastolic }

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
            Button(isExpanded ? "Done" : "Log") {
                withAnimation(.spring(duration: 0.25)) {
                    expandedDomain = isExpanded ? nil : domain
                }
            }
            .buttonStyle(TrackPillButtonStyle(tint: isExpanded ? Color(.secondaryLabel) : urgencyColor))
        case .openHealth:
            Button("Open Health") { onOpenHealth() }
                .buttonStyle(TrackPillButtonStyle(tint: .secondary))
        case .train:
            Button("Log workout") { onOpenTrain() }
                .buttonStyle(TrackPillButtonStyle(tint: urgencyColor))
        case .bloodwork:
            Button(card.item.status == .missing ? "Log panel" : "Open") { onOpenBloodwork() }
                .buttonStyle(TrackPillButtonStyle(tint: urgencyColor))
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
        if actionType == .openHealth || actionType == .bloodwork || actionType == .train {
            // Non-tappable — nothing useful to expand inline; primary action lives elsewhere.
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
        case .bloodPressure: bloodPressureControls
        case .nicotine:      nicotineControls
        case .alcohol:       alcoholControls
        case .dental:        dentalControls
        case .openHealth, .bloodwork, .train: EmptyView()
        }
    }

    private var bloodPressureControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                bpField(text: $bpSystolicText, placeholder: latestBP.map { String(Int($0.systolic)) } ?? "Sys", field: .systolic)
                Text("/").foregroundStyle(.secondary)
                bpField(text: $bpDiastolicText, placeholder: latestBP.map { String(Int($0.diastolic)) } ?? "Dia", field: .diastolic)
                Text("mmHg").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { saveBP() }
                    .buttonStyle(TrackPillButtonStyle(tint: bpIsValid ? .green : .secondary))
                    .disabled(!bpIsValid)
            }
            HStack(spacing: 8) {
                if let last = latestBP {
                    Text("Last: \(Int(last.systolic))/\(Int(last.diastolic)) · \(relativeTime(last.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Past reading…") { onOpenBPSheet() }
                    .font(.caption)
            }
        }
        .onAppear { bpFocus = .systolic }
    }

    private func bpField(text: Binding<String>, placeholder: String, field: BPField) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .focused($bpFocus, equals: field)
            .frame(width: 56)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var bpIsValid: Bool {
        guard let s = Double(bpSystolicText), let d = Double(bpDiastolicText) else { return false }
        return (60...250).contains(s) && (40...150).contains(d)
    }

    private func saveBP() {
        guard let s = Double(bpSystolicText), let d = Double(bpDiastolicText) else { return }
        onLogBP(s, d)
        bpSystolicText = ""
        bpDiastolicText = ""
        bpFocus = nil
        withAnimation(.spring(duration: 0.25)) { expandedDomain = nil }
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: .now)
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
                pillButton(title: flossedToday ? "Logged" : "Log", filled: flossedToday, tint: .green) {
                    onLogDentalFloss()
                }
            }
            HStack {
                Label("Fluoride gel", systemImage: "drop").font(.subheadline)
                Spacer()
                pillButton(title: fluorideToday ? "Logged" : "Log", filled: fluorideToday, tint: .green) {
                    onLogDentalFluoride()
                }
            }
        }
    }

    // MARK: - Helpers

    private func hasTodayEntry(type: ManualEntryType, value: Bool) -> Bool {
        let mostRecent = todaysEntries
            .filter { $0.entryType == type && Calendar.current.isDateInToday($0.date) }
            .sorted { $0.date > $1.date }
            .first
        return mostRecent?.booleanValue == value
    }

    private func todaysAlcoholLevel() -> AlcoholLevel? {
        todaysEntries
            .filter { $0.entryType == .alcohol && Calendar.current.isDateInToday($0.date) }
            .sorted { $0.date > $1.date }
            .first?.alcoholLevel
    }

    private var urgencyColor: Color {
        switch card.urgency {
        case .trackNow:   card.item.status == .urgent ? .red : AppTab.track.tint
        case .comingSoon: AppTab.track.tint
        case .onTrack:    .green
        }
    }

    private func pillButton(title: String, filled: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(filled ? tint : .primary)
                .glassEffect(
                    filled ? .regular.tint(tint.opacity(0.30)) : .regular,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(tint.opacity(filled ? 0.35 : 0.0), lineWidth: 0.8)
                )
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
            .foregroundStyle(tint)
            .glassEffect(
                .regular.tint(tint.opacity(configuration.isPressed ? 0.40 : 0.22)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.8)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
