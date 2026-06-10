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
        // Non-onTrack health items still show — surfacing them IS the reminder to open Health.
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
            return (item.status == .bad || item.status == .borderline || item.dataIsStale) ? .trackNow : .onTrack
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
