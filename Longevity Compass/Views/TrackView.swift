import SwiftUI
import SwiftData

struct TrackView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @Query(sort: \ManualEntry.date, order: .reverse) private var entries: [ManualEntry]

    @State private var savedNotice: String?
    @State private var showBPSheet = false

    var body: some View {
        Form {
            Section("Blood Pressure") {
                Button {
                    showBPSheet = true
                } label: {
                    Label("Log blood pressure", systemImage: "heart.text.square")
                }
            }

            Section("Tracked in Apple Health") {
                Text("Weight, sleep, and workouts live in Apple Health. The app reads them automatically and only nudges you if a trend drifts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    openURL(AppleHealthLink.url)
                } label: {
                    Label("Open Apple Health", systemImage: "heart.text.square")
                }
            }

            Section("Today's habits") {
                habitRow(type: .proteinHabit, label: "Protein in 2+ meals", systemImage: "fork.knife")
                habitRow(type: .fiberHabit, label: "Fibre-rich meal", systemImage: "leaf")
                habitRow(type: .omega3Habit, label: "Fatty fish meal", systemImage: "fish")
                habitRow(type: .dentalFloss, label: "Flossed", systemImage: "mouth")
                habitRow(type: .dentalFluoride, label: "Fluoride gel", systemImage: "drop")
                nicotineRow
            }

            Section("Alcohol today") {
                alcoholRow
            }

            Section {
                NavigationLink {
                    HistoryView()
                } label: {
                    Label("History (\(entries.count))", systemImage: "list.bullet.rectangle")
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

    // MARK: - Rows

    private func habitRow(type: ManualEntryType, label: String, systemImage: String) -> some View {
        let logged = hasLoggedToday(type: type, value: true)
        return HStack {
            Label(label, systemImage: systemImage)
            Spacer()
            if logged {
                Label("Logged", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Button {
                Task { await services.recordManualEntry(
                    ManualEntry(entryType: type, booleanValue: true)
                )}
                flash("Logged \(label.lowercased())")
            } label: {
                Text(logged ? "Log again" : "Log")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(logged ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var nicotineRow: some View {
        let usedToday = hasLoggedToday(type: .nicotine, value: true)
        let abstainedToday = hasLoggedToday(type: .nicotine, value: false)
        return HStack {
            Label("Nicotine", systemImage: "nosign")
            Spacer()
            HStack(spacing: 6) {
                pillButton(title: "None", filled: abstainedToday, tint: .green) {
                    Task { await services.recordManualEntry(
                        ManualEntry(entryType: .nicotine, booleanValue: false)
                    )}
                    flash("Logged: no nicotine today")
                }
                pillButton(title: "Used", filled: usedToday, tint: .red) {
                    Task { await services.recordManualEntry(
                        ManualEntry(entryType: .nicotine, booleanValue: true)
                    )}
                    flash("Logged nicotine use")
                }
            }
        }
    }

    private var alcoholRow: some View {
        let todays = todaysAlcoholLevel()
        return HStack(spacing: 6) {
            ForEach(AlcoholLevel.allCases) { level in
                pillButton(
                    title: level.displayLabel,
                    filled: todays == level,
                    tint: tint(for: level)
                ) {
                    Task { await services.recordManualEntry(
                        ManualEntry(entryType: .alcohol, categorical: level.rawValue)
                    )}
                    flash("Logged: \(level.displayLabel.lowercased())")
                }
            }
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

    private func tint(for level: AlcoholLevel) -> Color {
        switch level {
        case .none:  .green
        case .light: .yellow
        case .heavy: .red
        }
    }

    // MARK: - Helpers

    private func hasLoggedToday(type: ManualEntryType, value: Bool) -> Bool {
        let start = Calendar.current.startOfDay(for: .now)
        return entries.contains {
            $0.entryType == type
            && $0.date >= start
            && $0.booleanValue == value
        }
    }

    private func todaysAlcoholLevel() -> AlcoholLevel? {
        let start = Calendar.current.startOfDay(for: .now)
        let todays = entries
            .filter { $0.entryType == .alcohol && $0.date >= start }
            .sorted(by: { $0.date > $1.date })
        return todays.first?.alcoholLevel
    }

    private func flash(_ text: String) {
        withAnimation { savedNotice = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation { savedNotice = nil }
        }
    }
}
