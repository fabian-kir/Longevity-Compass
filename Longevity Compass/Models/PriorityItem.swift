import Foundation

struct PriorityItem: Identifiable, Hashable {
    let id = UUID()
    let domain: HealthDomain
    let status: DomainStatus
    let trend: TrendDirection
    let priorityScore: Double
    let impactWeight: Double
    let reason: String
    let currentValueDescription: String
    let trendDescription: String
    let recommendedActions: [String]
    let nextTrackingDate: Date?
    let reminderFrequency: ReminderFrequency
    let dataIsStale: Bool

    var title: String { domain.displayName }
    var rationale: String { domain.rationale }
    var systemImageName: String { domain.systemImageName }

    /// Returns a copy with the reminder frequency (and recomputed next-tracking date) overridden.
    /// Used by `PriorityEngine` to bump cadence when a high-impact domain is trending the wrong way.
    func withReminderCadence(
        _ frequency: ReminderFrequency,
        nextTrackingDate: Date?
    ) -> PriorityItem {
        PriorityItem(
            domain: domain,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: impactWeight,
            reason: reason,
            currentValueDescription: currentValueDescription,
            trendDescription: trendDescription,
            recommendedActions: recommendedActions,
            nextTrackingDate: nextTrackingDate,
            reminderFrequency: frequency,
            dataIsStale: dataIsStale
        )
    }
}

enum OverallStatus: String {
    case onTrack
    case needsAttention
    case highPriority

    var headline: String {
        switch self {
        case .onTrack:          "On track"
        case .needsAttention:   "Needs attention"
        case .highPriority:     "High priority"
        }
    }

    var supportingLine: String {
        switch self {
        case .onTrack:
            return "Nothing urgent. Keep the good habits going."
        case .needsAttention:
            return "A few items would benefit from a little focus this week."
        case .highPriority:
            return "At least one high-impact item is off-track. Start there."
        }
    }
}
