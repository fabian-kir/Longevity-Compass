import SwiftUI

struct FocusView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let result = services.currentResult {
                    if result.topItems.isEmpty {
                        allClearState
                    } else {
                        FocusHeroCard(item: result.topItems[0])

                        if result.topItems.count > 1 {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Also on the radar")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 4)

                                VStack(spacing: 8) {
                                    ForEach(Array(result.topItems.dropFirst())) { item in
                                        NavigationLink(value: item) {
                                            CompactPriorityRow(item: item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                } else if services.isRefreshing {
                    ProgressView("Reading your data…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .navigationTitle("Focus")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: PriorityItem.self) { item in
            ScrollView {
                PriorityCardView(item: item)
                    .padding()
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .refreshable { await services.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await services.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
        }
    }

    private var allClearState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.green)
            Text("All clear")
                .font(.title2.weight(.semibold))
            Text("Nothing urgent right now. Keep the good habits going.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Hero card (the one thing to focus on)

private struct FocusHeroCard: View {
    let item: PriorityItem

    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            heroHeader

            Text(item.reason)
                .font(.title3)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.currentValueDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !item.recommendedActions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Do this")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(item.recommendedActions.prefix(2), id: \.self) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(tint)
                            Text(action)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            primaryActionButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 1.5)
        )
    }

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.systemImageName)
                .font(.system(size: 32, weight: .semibold))
                .frame(width: 64, height: 64)
                .foregroundStyle(.white)
                .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Top priority")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .textCase(.uppercase)
                Text(item.title)
                    .font(.system(.largeTitle, design: .default).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(item.status.displayLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch AppleHealthLink.destination(for: item.domain) {
        case .appleHealth:
            Button {
                openURL(AppleHealthLink.url)
            } label: {
                actionLabel(icon: "heart.text.square", text: "Open Apple Health", trailing: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
        case .trackTab:
            Button {
                services.selectedTab = .track
            } label: {
                actionLabel(icon: "square.and.pencil", text: "Log in app", trailing: "chevron.right")
            }
            .buttonStyle(.plain)
        }
    }

    private func actionLabel(icon: String, text: String, trailing: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text).font(.body.weight(.semibold))
            Spacer()
            Image(systemName: trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.white)
    }

    private var tint: Color {
        statusTint(item.status)
    }
}

// MARK: - Compact row (secondary items)

private struct CompactPriorityRow: View {
    let item: PriorityItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImageName)
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(tint)
                .background(tint.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.currentValueDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.status.displayLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var tint: Color {
        statusTint(item.status)
    }
}

// MARK: - Shared status color

private func statusTint(_ status: DomainStatus) -> Color {
    switch status {
    case .urgent, .bad:    .red
    case .borderline:      .orange
    case .good:            .green
    case .missing:         .blue
    case .unknown:         .gray
    }
}
