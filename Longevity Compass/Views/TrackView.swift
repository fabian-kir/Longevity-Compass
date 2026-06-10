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
