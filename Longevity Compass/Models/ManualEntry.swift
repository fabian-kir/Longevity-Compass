import Foundation
import SwiftData

enum ManualEntryType: String, Codable, CaseIterable {
    case bloodPressure
    case waist
    case bodyWeight
    case proteinHabit
    case fiberHabit
    case omega3Habit
    case strengthTraining
    case dentalFloss
    case dentalFluoride
    case alcohol
    case nicotine

    var domain: HealthDomain {
        switch self {
        case .bloodPressure:                            .bloodPressure
        case .waist, .bodyWeight:                       .bodyComposition
        case .proteinHabit:                             .protein
        case .fiberHabit:                               .fiber
        case .omega3Habit:                              .omega3
        case .strengthTraining:                         .strength
        case .dentalFloss, .dentalFluoride:             .dental
        case .alcohol:                                  .alcohol
        case .nicotine:                                 .nicotine
        }
    }
}

@Model
final class ManualEntry {
    var id: UUID
    var entryTypeRaw: String
    var date: Date
    var primaryValue: Double?
    var secondaryValue: Double?
    var tertiaryValue: Double?
    var booleanValue: Bool?
    var categoricalRaw: String?
    var notes: String?

    init(
        id: UUID = UUID(),
        entryType: ManualEntryType,
        date: Date = .now,
        primaryValue: Double? = nil,
        secondaryValue: Double? = nil,
        tertiaryValue: Double? = nil,
        booleanValue: Bool? = nil,
        categorical: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.entryTypeRaw = entryType.rawValue
        self.date = date
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
        self.tertiaryValue = tertiaryValue
        self.booleanValue = booleanValue
        self.categoricalRaw = categorical
        self.notes = notes
    }

    var entryType: ManualEntryType {
        ManualEntryType(rawValue: entryTypeRaw) ?? .nicotine
    }

    var alcoholLevel: AlcoholLevel? {
        guard let raw = categoricalRaw else { return nil }
        return AlcoholLevel(rawValue: raw)
    }
}
