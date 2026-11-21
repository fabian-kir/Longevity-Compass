import Foundation
import SwiftData

/// One stretch of opted-in Digestion Insights tracking. Active period: `end == nil`.
@Model
final class DigestionTrackingPeriod {
    var id: UUID
    var start: Date
    var end: Date?

    init(id: UUID = UUID(), start: Date, end: Date? = nil) {
        self.id = id
        self.start = start
        self.end = end
    }

    var isActive: Bool { end == nil }
}
