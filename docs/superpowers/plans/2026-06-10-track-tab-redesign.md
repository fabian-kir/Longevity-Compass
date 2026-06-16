# Track Tab — Smart Tracking Recommendations

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Track tab's flat input form with a priority-sorted list of adaptive tracking cards that surfaces only what genuinely needs attention and backs off when things are good.

**Architecture:** A new `TrackingRecommendationEngine` maps existing `PriorityItem` results (already computed by `PriorityEngine`) into `TrackingCard` view-models. Cards are sorted into three buckets: Track Now / Coming Up / You're Good. In-app trackable items (BP, nicotine, alcohol, dental) expand inline for logging. Apple-Health-backed items (cardio, sleep, strength, body comp) show an "Open Health" deep-link button only when attention is needed — they are hidden when truly good to reduce noise. A new `TrackingCardView` component encapsulates the per-card UI. `TrackView` is rewritten to consume these cards.

**Tech Stack:** Swift, SwiftUI, SwiftData, `@Observable` (AppServices), existing `PriorityItem` / `HealthDomain` / `ManualEntry` models, `AppleHealthLink`.

---

### Task 1: Create `TrackingRecommendationEngine`

**Files:**
- Create: `Longevity Compass/Services/TrackingRecommendationEngine.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

struct TrackingCard: Identifiable {
    let id = UUID()
    let item: PriorityItem
    let urgency: TrackingUrgency
    let dueInDays: Int?       // nil → no reminder schedule
    let contextLine: String
}

enum TrackingUrgency: Int, Comparable {
    case trackNow = 0
    case comingSoon = 1
    case onTrack = 2

    static func < (lhs: TrackingUrgency, rhs: TrackingUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var sectionTitle: String {
        switch self {
        case .trackNow:   "Track Now"
        case .comingSoon: "Coming Up"
        case .onTrack:    "You're Good"
        }
    }
}

enum TrackActionType: Equatable {
    case bloodPressure
    case nicotine
    case alcohol
    case dental
    case openHealth
}

enum TrackingRecommendationEngine {
    // Protein, fiber, omega3 intentionally excluded — they live in the Nutrition tab.
    static let relevantDomains: [HealthDomain] = [
        .bloodPressure, .nicotine, .cardio, .strength,
        .bodyComposition, .sleep, .alcohol, .dental,
    ]

    // Auto-tracked by Apple Health — only surface when attention is needed.
    private static let healthBackedDomains: Set<HealthDomain> = [
        .cardio, .sleep, .strength, .bodyComposition,
    ]

    /// Returns cards sorted by urgency (Track Now first), then by priorityScore descending.
    /// Health-backed domains that are fully good are excluded to reduce noise.
    static func cards(from items: [PriorityItem], now: Date = .now) -> [TrackingCard] {
        relevantDomains
            .compactMap { domain in items.first { $0.domain == domain } }
            .map { card(from: $0, now: now) }
            .filter { shouldShow($0) }
            .sorted {
                if $0.urgency != $1.urgency { return $0.urgency < $1.urgency }
                return $0.item.priorityScore > $1.item.priorityScore
            }
    }

    static func actionType(for domain: HealthDomain) -> TrackActionType {
        switch domain {
        case .bloodPressure: return .bloodPressure
        case .nicotine:      return .nicotine
        case .alcohol:       return .alcohol
        case .dental:        return .dental
        default:             return .openHealth
        }
    }

    // MARK: - Private

    private static func shouldShow(_ card: TrackingCard) -> Bool {
        // Non-onTrack cards always show.
        guard card.urgency == .onTrack else { return true }
        // Health-backed domains with truly good, fresh data add no value in "You're Good".
        if healthBackedDomains.contains(card.item.domain) {
            return card.item.status != .good || card.item.dataIsStale
        }
        return true
    }

    private static func card(from item: PriorityItem, now: Date) -> TrackingCard {
        let dueInDays: Int? = item.nextTrackingDate.map {
            Calendar.current.dateComponents([.day], from: now, to: $0).day ?? 0
        }
        return TrackingCard(
            item: item,
            urgency: computeUrgency(item: item, dueInDays: dueInDays),
            dueInDays: dueInDays,
            contextLine: buildContextLine(item: item, dueInDays: dueInDays)
        )
    }

    private static func computeUrgency(item: PriorityItem, dueInDays: Int?) -> TrackingUrgency {
        if item.status == .urgent || item.status == .missing { return .trackNow }
        guard let days = dueInDays else {
            return (item.status == .bad || item.dataIsStale) ? .trackNow : .onTrack
        }
        switch days {
        case ...0:  return .trackNow
        case 1...3: return .comingSoon
        default:    return .onTrack
        }
    }

    private static func buildContextLine(item: PriorityItem, dueInDays: Int?) -> String {
        var parts: [String] = []
        let ignoredDescs: Set<String> = [
            "No readings", "No data", "No sleep data",
            "No nicotine logged", "No recent use", "",
        ]
        if !ignoredDescs.contains(item.currentValueDescription) {
            parts.append(item.currentValueDescription)
        }
        switch item.trend {
        case .worsening: parts.append("Trending worse")
        case .improving: parts.append("Improving")
        default: break
        }
        if let days = dueInDays, days < 0 {
            parts.append("Overdue by \(-days)d")
        } else if item.dataIsStale {
            parts.append("Data may be stale")
        }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 2: Build (`⌘B`)** — Expected: no errors or warnings.

- [ ] **Step 3: Commit**

```bash
git add "Longevity Compass/Services/TrackingRecommendationEngine.swift"
git commit -m "feat: add TrackingRecommendationEngine with adaptive card urgency"
```

---

### Task 2: Create `TrackingCardView`

**Files:**
- Create: `Longevity Compass/Views/TrackingCardView.swift`

- [ ] **Step 1: Create the file**

```swift
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
```

- [ ] **Step 2: Build (`⌘B`)** — Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add "Longevity Compass/Views/TrackingCardView.swift"
git commit -m "feat: add TrackingCardView with inline logging and Health deep-link"
```

---

### Task 3: Rewrite `TrackView`

**Files:**
- Modify: `Longevity Compass/Views/TrackView.swift`

Replace the entire file with the following content:

- [ ] **Step 1: Replace `TrackView.swift`**

```swift
import SwiftUI
import SwiftData

struct TrackView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @Query(sort: \ManualEntry.date, order: .reverse) private var allEntries: [ManualEntry]

    @State private var showBPSheet = false
    @State private var expandedDomain: HealthDomain? = nil
    @State private var savedNotice: String? = nil

    private var cards: [TrackingCard] {
        TrackingRecommendationEngine.cards(from: services.currentResult?.allItems ?? [])
    }

    private var trackNowCards:  [TrackingCard] { cards.filter { $0.urgency == .trackNow } }
    private var comingSoonCards: [TrackingCard] { cards.filter { $0.urgency == .comingSoon } }
    private var onTrackCards:   [TrackingCard] { cards.filter { $0.urgency == .onTrack } }

    var body: some View {
        Form {
            if trackNowCards.isEmpty && comingSoonCards.isEmpty {
                allGoodSection
            } else {
                if !trackNowCards.isEmpty {
                    Section("Track Now") {
                        ForEach(trackNowCards) { card in cardRow(card) }
                    }
                }
                if !comingSoonCards.isEmpty {
                    Section("Coming Up") {
                        ForEach(comingSoonCards) { card in cardRow(card) }
                    }
                }
            }

            if !onTrackCards.isEmpty {
                Section("You're Good") {
                    ForEach(onTrackCards) { card in cardRow(card) }
                }
            }

            Section {
                NavigationLink {
                    HistoryView()
                } label: {
                    Label("History (\(allEntries.count))", systemImage: "list.bullet.rectangle")
                }
            } footer: {
                Text("Edit or delete any logged entry from history.")
            }
        }
        .navigationTitle("Track")
        .sheet(isPresented: $showBPSheet) {
            BloodPressureEntrySheet()
        }
        .overlay(alignment: .bottom) {
            if let notice = savedNotice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Card row

    private func cardRow(_ card: TrackingCard) -> some View {
        TrackingCardView(
            card: card,
            expandedDomain: $expandedDomain,
            todaysEntries: allEntries,
            onMeasureBP: {
                showBPSheet = true
            },
            onLogNicotine: { used in
                Task { await services.recordManualEntry(ManualEntry(entryType: .nicotine, booleanValue: used)) }
                flash(used ? "Logged nicotine use" : "Logged: no nicotine today")
            },
            onLogAlcohol: { level in
                Task { await services.recordManualEntry(ManualEntry(entryType: .alcohol, categorical: level.rawValue)) }
                flash("Logged: \(level.displayLabel.lowercased())")
            },
            onLogDentalFloss: {
                Task { await services.recordManualEntry(ManualEntry(entryType: .dentalFloss, booleanValue: true)) }
                flash("Logged flossing")
            },
            onLogDentalFluoride: {
                Task { await services.recordManualEntry(ManualEntry(entryType: .dentalFluoride, booleanValue: true)) }
                flash("Logged fluoride gel")
            },
            onOpenHealth: {
                openURL(AppleHealthLink.url)
            }
        )
    }

    // MARK: - Empty state

    private var allGoodSection: some View {
        Section {
            VStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                Text("Nothing to track right now")
                    .font(.subheadline.weight(.semibold))
                Text("The app will surface items here when they need attention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Flash notice

    private func flash(_ text: String) {
        withAnimation { savedNotice = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation { savedNotice = nil }
        }
    }
}
```

- [ ] **Step 2: Build (`⌘B`)** — Expected: no errors.

- [ ] **Step 3: Run in simulator**, navigate to Track tab. Verify:
  - **"Track Now" section** shows overdue/urgent/missing items with correct urgency colors (red/orange)
  - **"Coming Up" section** shows items due within 3 days (yellow)
  - **"You're Good" section** shows in-app items with green badge + "Next in Xd" label
  - **Blood pressure card**: tapping "Measure" opens `BloodPressureEntrySheet`
  - **Nicotine card**: tapping "Log today" expands to show None / Used pill buttons; tapping a pill logs the entry and flashes a confirmation
  - **Alcohol card**: tapping "Log today" expands None / Light / Heavy; pill buttons reflect today's logged level
  - **Dental card**: tapping "Log today" expands Flossed and Fluoride rows; each has its own Log button
  - **Cardio / Sleep / Strength / BodyComp**: show "Open Health" button; tapping opens Apple Health
  - **Protein, fiber, fatty fish**: not present anywhere on this tab
  - **Empty state**: if all items are onTrack and health-backed items are hidden, "Nothing to track right now" appears
  - **History link** still navigates to `HistoryView`

- [ ] **Step 4: Commit**

```bash
git add "Longevity Compass/Views/TrackView.swift"
git commit -m "feat: rewrite Track tab with adaptive priority-sorted tracking cards

Remove protein/fiber/omega3 from track tab (moved to Nutrition).
Add TrackingRecommendationEngine-driven cards sorted by urgency.
In-app metrics expand inline; Apple Health metrics deep-link to Health."
```

---

### Self-review checklist

- [x] **Spec coverage:** Three sections (Track Now / Coming Up / You're Good) ✓ · Protein/fiber/omega3 removed ✓ · In-app inline controls ✓ · Apple Health deep-link ✓ · Adaptive intervals via existing `nextTrackingDate` from PriorityEngine ✓ · Empty "nothing to track" state ✓
- [x] **Placeholder scan:** No TBDs or TODOs.
- [x] **Type consistency:** `TrackingCard`, `TrackingUrgency`, `TrackActionType`, `TrackingRecommendationEngine` defined in Task 1 and used consistently in Tasks 2–3. `ManualEntry(entryType:booleanValue:)` and `ManualEntry(entryType:categorical:)` match the actual initializer in `ManualEntry.swift`. `AlcoholLevel.allCases`, `level.rawValue`, `level.displayLabel` all match `HealthDomain.swift`. `AppleHealthLink.healthLocationHint(for:)` exists in `AppleHealthLink.swift`.
