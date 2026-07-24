import Foundation
import SwiftData

enum BloodworkFlag: String, Codable, CaseIterable, Identifiable {
    case good
    case borderline
    case bad
    case unknown

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .good:       "Good"
        case .borderline: "Borderline"
        case .bad:        "Bad"
        case .unknown:    "Unsure"
        }
    }

    var domainStatus: DomainStatus {
        switch self {
        case .good:       .good
        case .borderline: .borderline
        case .bad:        .bad
        case .unknown:    .unknown
        }
    }
}

@Model
final class BloodworkPanel {
    var id: UUID
    var date: Date
    var labName: String?
    var notes: String?
    /// True when the user reports the panel was drawn during illness or injury.
    /// The evaluator suppresses good/borderline/bad colouring on acute-phase
    /// reactants (hs-CRP, ferritin, albumin) in that case — the numbers are
    /// real but the interpretation isn't.
    var acutePhaseAtDraw: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \BloodworkMarker.panel)
    var markers: [BloodworkMarker]

    init(
        id: UUID = UUID(),
        date: Date = .now,
        labName: String? = nil,
        notes: String? = nil,
        acutePhaseAtDraw: Bool = false,
        markers: [BloodworkMarker] = []
    ) {
        self.id = id
        self.date = date
        self.labName = labName
        self.notes = notes
        self.acutePhaseAtDraw = acutePhaseAtDraw
        self.markers = markers
    }

    /// Worst flag among markers — drives the recheck cadence.
    var worstFlag: BloodworkFlag {
        if markers.contains(where: { $0.flag == .bad })        { return .bad }
        if markers.contains(where: { $0.flag == .borderline }) { return .borderline }
        if markers.allSatisfy({ $0.flag == .good })            { return .good }
        return .unknown
    }
}

@Model
final class BloodworkMarker {
    var id: UUID
    var name: String
    var value: String         // free-form so units / qualifiers ("<5", "negative") work
    var unit: String?
    var referenceRange: String?
    var flagRaw: String
    var panel: BloodworkPanel?

    init(
        id: UUID = UUID(),
        name: String,
        value: String = "",
        unit: String? = nil,
        referenceRange: String? = nil,
        flag: BloodworkFlag = .unknown
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
        self.flagRaw = flag.rawValue
    }

    var flag: BloodworkFlag {
        get { BloodworkFlag(rawValue: flagRaw) ?? .unknown }
        set { flagRaw = newValue.rawValue }
    }

    /// Parsed numeric form of `value`. Returns nil for qualified inputs like
    /// `"<5"`, `"negative"`, `"trace"` — those stay as text and don't get flagged.
    var numericValue: Double? {
        BloodworkEvaluator.parseNumeric(value)
    }
}

/// Catalog of longevity-relevant markers prefilled when starting a new panel.
/// The catalog is now driven from `Resources/bloodwork_markers.json` — single
/// source of truth shared with the evaluator. The `Suggestion` shape is kept
/// for existing call sites (entry sheet rows, marker-guide rows).
nonisolated enum BloodworkMarkerCatalog {

    enum Tier: String, CaseIterable, Identifiable {
        case core
        case extended
        case specialized

        var id: String { rawValue }

        var title: String {
            switch self {
            case .core:        "Core panel"
            case .extended:    "Extended"
            case .specialized: "Specialized"
            }
        }

        var subtitle: String {
            switch self {
            case .core:
                "High value-per-dollar. Ask for these every time."
            case .extended:
                "Useful add-ons if budget allows or symptoms warrant."
            case .specialized:
                "Only worth ordering if you have a specific reason."
            }
        }

        fileprivate var raw: String { rawValue }

        fileprivate static func from(_ raw: String) -> Tier? {
            Tier(rawValue: raw)
        }
    }

    struct Suggestion: Identifiable {
        let id: String
        let name: String
        let unit: String
        let tier: Tier
        /// One-line "what this signals" — shown inline next to the marker row.
        let purpose: String
        /// Longer explanation — shown in the marker guide / per-marker sheet.
        let detail: String
    }

    static let defaults: [Suggestion] = BloodworkResearch.all.compactMap { entry in
        guard let tier = Tier.from(entry.tier) else { return nil }
        return Suggestion(
            id: entry.id,
            name: entry.name,
            unit: entry.unit.primary,
            tier: tier,
            purpose: entry.whatItSignals,
            detail: entry.description
        )
    }

    static func suggestions(for tier: Tier) -> [Suggestion] {
        defaults.filter { $0.tier == tier }
    }
}
