import Foundation
import SwiftData

@Model
final class PriorityHistoryEntry {
    var id: UUID
    var generatedAt: Date
    var domainRaw: String
    var statusRaw: String
    var trendRaw: String
    var priorityScore: Double
    var reason: String

    init(
        id: UUID = UUID(),
        generatedAt: Date = .now,
        domain: HealthDomain,
        status: DomainStatus,
        trend: TrendDirection,
        priorityScore: Double,
        reason: String
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.domainRaw = domain.rawValue
        self.statusRaw = status.rawValue
        self.trendRaw = trend.rawValue
        self.priorityScore = priorityScore
        self.reason = reason
    }

    var domain: HealthDomain? { HealthDomain(rawValue: domainRaw) }
    var status: DomainStatus { DomainStatus(rawValue: statusRaw) ?? .unknown }
    var trend: TrendDirection { TrendDirection(rawValue: trendRaw) ?? .unknown }
}
