import SwiftUI

struct DashboardView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusHeader

                if let result = services.currentResult {
                    if result.topItems.isEmpty {
                        emptyTopState
                    } else {
                        VStack(spacing: 16) {
                            ForEach(result.topItems) { item in
                                PriorityCardView(item: item)
                            }
                        }
                    }
                } else if services.isRefreshing {
                    ProgressView("Reading your data…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.large)
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

    private var overallStatus: OverallStatus {
        services.currentResult?.overallStatus ?? .onTrack
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: headerSymbol)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(headerTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(overallStatus.headline)
                        .font(.title2.weight(.semibold))
                    Text(overallStatus.supportingLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let date = services.healthKit.lastSyncDate {
                Text("Updated \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var headerTint: Color {
        switch overallStatus {
        case .onTrack:         .green
        case .needsAttention:  .orange
        case .highPriority:    .red
        }
    }

    private var headerSymbol: String {
        switch overallStatus {
        case .onTrack:         "checkmark.seal.fill"
        case .needsAttention:  "exclamationmark.triangle.fill"
        case .highPriority:    "exclamationmark.octagon.fill"
        }
    }

    private var emptyTopState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing urgent")
                .font(.headline)
            Text("Once Apple Health permissions are granted and a few habits are logged, the most important items will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
