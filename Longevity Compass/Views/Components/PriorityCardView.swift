import SwiftUI

struct PriorityCardView: View {
    let item: PriorityItem

    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @State private var showWhy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 16) {
                ValueRow(icon: "circle.dashed", label: "Now",   value: item.currentValueDescription)
                Divider().frame(height: 32)
                ValueRow(icon: item.trend.arrowSymbol, label: "Trend", value: item.trendDescription)
            }

            Text(item.reason)
                .font(.subheadline)
                .foregroundStyle(.primary)

            if !item.recommendedActions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What to do next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(item.recommendedActions.prefix(3), id: \.self) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(action).font(.subheadline)
                        }
                    }
                    if item.recommendedActions.count > 3 {
                        DisclosureGroup("More") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(item.recommendedActions.dropFirst(3), id: \.self) { action in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(action).font(.subheadline)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption.weight(.semibold))
                        .tint(.secondary)
                    }
                }
            }

            DisclosureGroup(isExpanded: $showWhy) {
                Text(item.rationale)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } label: {
                Text("Why this matters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            trackNowButton

            HStack {
                if let next = item.nextTrackingDate, item.reminderFrequency != .never {
                    Label("Next check \(next.formatted(.relative(presentation: .named)))", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.reminderFrequency != .never {
                    Text("Every: \(item.reminderFrequency.displayLabel.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No reminders while stable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(statusTint.opacity(0.35), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImageName)
                .font(.title3.weight(.semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(statusTint)
                .background(statusTint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.headline)
                Text(item.status.displayLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
            }
            Spacer()
            if item.dataIsStale {
                Text("Track now")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(statusTint, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private var trackNowButton: some View {
        switch AppleHealthLink.destination(for: item.domain) {
        case .appleHealth:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    openURL(AppleHealthLink.url)
                } label: {
                    HStack {
                        Image(systemName: "heart.text.square")
                        Text("Open Apple Health")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(statusTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(statusTint)
                }
                .buttonStyle(.plain)
                if let hint = AppleHealthLink.healthLocationHint(for: item.domain) {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .trackTab:
            Button {
                services.selectedTab = .track
            } label: {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text("Log in app")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(statusTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(statusTint)
            }
            .buttonStyle(.plain)
        }
    }

    private var statusTint: Color {
        switch item.status {
        case .urgent:        .red
        case .bad:           .red
        case .borderline:    .orange
        case .good:          .green
        case .missing:       .blue
        case .unknown:       .gray
        }
    }
}

private struct ValueRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(value).font(.subheadline).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
