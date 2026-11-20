import Foundation
import SwiftData

enum SymptomLevel: String, Codable, CaseIterable, Identifiable {
    case noticeable
    case bothersome
    case disruptedDay
    case mild
    case severe
    case loose
    case watery
    case present

    var id: String { rawValue }

    var label: String {
        switch self {
        case .noticeable:   return "Noticeable"
        case .bothersome:   return "Bothersome"
        case .disruptedDay: return "Disrupted my day"
        case .mild:         return "Mild"
        case .severe:       return "Severe"
        case .loose:        return "Loose"
        case .watery:       return "Watery"
        case .present:      return "More than usual"
        }
    }
}

enum SymptomKind: String, Codable, CaseIterable, Identifiable {
    case abdominalPain
    case bloating
    case diarrhoea
    case gas
    case nausea
    case heartburn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .abdominalPain: return "Abdominal pain"
        case .bloating:      return "Bloating"
        case .diarrhoea:     return "Diarrhoea"
        case .gas:           return "Gas"
        case .nausea:        return "Nausea"
        case .heartburn:     return "Heartburn"
        }
    }

    /// Ordered low to high.
    var levels: [SymptomLevel] {
        switch self {
        case .abdominalPain: return [.noticeable, .bothersome, .disruptedDay]
        case .bloating:      return [.mild, .severe]
        case .diarrhoea:     return [.loose, .watery]
        case .gas:           return [.present]
        case .nausea:        return [.mild, .severe]
        case .heartburn:     return [.mild, .severe]
        }
    }

    /// Gas has a single level, so the picker is skipped.
    var hasLevelChoice: Bool { levels.count > 1 }

    func rank(of level: SymptomLevel) -> Int? {
        levels.firstIndex(of: level)
    }

    func isTopLevel(_ level: SymptomLevel) -> Bool {
        levels.last == level
    }
}

@Model
final class SymptomEntry {
    var id: UUID
    var onset: Date
    var loggedAt: Date
    var kindRaw: String
    var levelRaw: String

    init(
        id: UUID = UUID(),
        onset: Date,
        loggedAt: Date = .now,
        kind: SymptomKind,
        level: SymptomLevel
    ) {
        self.id = id
        self.onset = onset
        self.loggedAt = loggedAt
        self.kindRaw = kind.rawValue
        self.levelRaw = level.rawValue
    }

    var kind: SymptomKind? {
        get { SymptomKind(rawValue: kindRaw) }
        set { if let newValue { kindRaw = newValue.rawValue } }
    }

    var level: SymptomLevel? {
        get { SymptomLevel(rawValue: levelRaw) }
        set { if let newValue { levelRaw = newValue.rawValue } }
    }

    var rank: Int? {
        guard let kind, let level else { return nil }
        return kind.rank(of: level)
    }

    var isTopLevel: Bool {
        guard let kind, let level else { return false }
        return kind.isTopLevel(level)
    }
}

/// Maps the onset picker choices to dates. Pure logic, kept out of the sheet.
enum SymptomOnsetChoice: String, CaseIterable, Identifiable {
    case now
    case oneHourAgo
    case threeHoursAgo
    case earlier

    var id: String { rawValue }

    var label: String {
        switch self {
        case .now:           return "Now"
        case .oneHourAgo:    return "1 h ago"
        case .threeHoursAgo: return "3 h ago"
        case .earlier:       return "Earlier…"
        }
    }

    /// Date for the choice, clamped into `periodStart ... now`.
    /// `custom` is only used for `.earlier`.
    func date(now: Date, periodStart: Date, custom: Date? = nil) -> Date {
        let raw: Date
        switch self {
        case .now:           raw = now
        case .oneHourAgo:    raw = now.addingTimeInterval(-3600)
        case .threeHoursAgo: raw = now.addingTimeInterval(-3 * 3600)
        case .earlier:       raw = custom ?? now
        }
        return Self.clamp(raw, periodStart: periodStart, now: now)
    }

    static func clamp(_ date: Date, periodStart: Date, now: Date) -> Date {
        min(max(date, periodStart), now)
    }
}
