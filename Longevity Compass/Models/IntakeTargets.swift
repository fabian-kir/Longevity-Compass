import Foundation

/// The amounts tracked against a user-set target: energy, the three macros and fibre.
enum IntakeNutrient: String, CaseIterable, Identifiable {
    case energy
    case protein
    case carbs
    case fat
    case fiber

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .energy:  "Calories"
        case .protein: "Protein"
        case .carbs:   "Carbs"
        case .fat:     "Fat"
        case .fiber:   "Fibre"
        }
    }

    var unit: String {
        self == .energy ? "kcal" : "g"
    }

    static let macros: [IntakeNutrient] = [.protein, .carbs, .fat, .fiber]
}

/// What the calorie target means. The raw values match the stored
/// `nutrition.energyIntent` values from the earlier "energy guide".
enum EnergyGoal: String, CaseIterable, Identifiable {
    case deficit
    case maintain
    case surplus

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .deficit:  "Deficit"
        case .maintain: "Maintain"
        case .surplus:  "Surplus"
        }
    }

    var detail: String {
        switch self {
        case .deficit:  "The target is a ceiling. Stay at or below it."
        case .maintain: "The target is your maintenance intake. Aim to land close to it."
        case .surplus:  "The target is a floor. Eat at least this much."
        }
    }
}

/// Whether reaching a target is the goal (protein) or exceeding it is the problem (calories in a deficit).
enum IntakeTargetKind {
    case minimum
    case limit
}

/// Daily targets. A nil or zero value means the user tracks the nutrient without a target.
struct IntakeTargets: Equatable {
    var energyKcal: Double?
    var energyGoal: EnergyGoal = .maintain
    var proteinGrams: Double?
    var carbsGrams: Double?
    var fatGrams: Double?
    var fiberGrams: Double?

    func daily(_ nutrient: IntakeNutrient) -> Double? {
        let value: Double? = switch nutrient {
        case .energy:  energyKcal
        case .protein: proteinGrams
        case .carbs:   carbsGrams
        case .fat:     fatGrams
        case .fiber:   fiberGrams
        }
        guard let value, value > 0 else { return nil }
        return value
    }

    func kind(for nutrient: IntakeNutrient) -> IntakeTargetKind {
        switch nutrient {
        case .energy:          energyGoal == .surplus ? .minimum : .limit
        case .protein, .fiber: .minimum
        case .carbs, .fat:     .limit
        }
    }
}

/// How consumed amounts are grouped before they are compared with the target.
enum IntakeWindowMode: String, CaseIterable, Identifiable {
    /// One calendar day. The default.
    case daily
    /// Consecutive blocks of N days, counted from an anchor date. Resets at the end of each block.
    case fixed
    /// The trailing N days, including today. Never resets; the oldest day drops out each midnight.
    case rolling

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .daily:   "Daily"
        case .fixed:   "Fixed blocks"
        case .rolling: "Rolling"
        }
    }
}

struct IntakeWindow: Equatable {
    var mode: IntakeWindowMode = .daily
    /// Window length in days. Ignored for `.daily`.
    var length: Int = IntakeSettings.Default.windowLength
    /// Any day on which a fixed block starts. Ignored for other modes.
    var anchor: Date = Date(timeIntervalSinceReferenceDate: 0)

    var effectiveLength: Int {
        mode == .daily ? 1 : max(1, length)
    }
}

/// `@AppStorage` keys and defaults shared by the intake card and its settings sheet.
enum IntakeSettings {
    enum Key {
        // Keeps the key of the earlier "energy guide", so a guide the user set carries over.
        // Users who never touched the guide start without a calorie target.
        static let calorieTarget = "nutrition.energyGuideKcal"
        static let energyGoal = "nutrition.energyIntent"
        static let proteinTarget = "nutrition.proteinTargetGrams"
        static let carbsTarget = "nutrition.carbsTargetGrams"
        static let fatTarget = "nutrition.fatTargetGrams"
        static let fiberTarget = "nutrition.fiberTargetGrams"
        static let windowMode = "nutrition.intakeWindowMode"
        static let windowLength = "nutrition.intakeWindowDays"
        static let windowAnchor = "nutrition.intakeWindowAnchor"
    }

    enum Default {
        /// 25–29 g/day is where the Reynolds 2019 Lancet meta-analysis saw the largest
        /// mortality benefit; 30 g is the common rounded public-health target.
        static let fiberTarget = 30.0
        static let windowLength = 3
    }

    static let windowLengthRange = 2...14
}
