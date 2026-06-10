import Foundation

enum HealthDomain: String, Codable, CaseIterable, Identifiable {
    case bloodPressure
    case nicotine
    case cardio
    case strength
    case bodyComposition
    case sleep
    case alcohol
    case protein
    case fiber
    case omega3
    case dental

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bloodPressure:    "Blood Pressure"
        case .nicotine:         "Nicotine"
        case .cardio:           "Cardio Activity"
        case .strength:         "Strength Training"
        case .bodyComposition:  "Body Composition"
        case .sleep:            "Sleep"
        case .alcohol:          "Alcohol"
        case .protein:          "Protein"
        case .fiber:            "Fiber"
        case .omega3:           "Omega-3 / Fatty Fish"
        case .dental:           "Dental Routine"
        }
    }

    var systemImageName: String {
        switch self {
        case .bloodPressure:    "heart.text.square"
        case .nicotine:         "nosign"
        case .cardio:           "figure.run"
        case .strength:         "dumbbell"
        case .bodyComposition:  "figure.arms.open"
        case .sleep:            "bed.double"
        case .alcohol:          "wineglass"
        case .protein:          "fork.knife"
        case .fiber:            "leaf"
        case .omega3:           "fish"
        case .dental:           "mouth"
        }
    }

    var rationale: String {
        switch self {
        case .bloodPressure:
            return "Sustained high blood pressure is one of the single largest modifiable risks for stroke, heart attack, kidney disease, and dementia. Trends matter much more than one reading."
        case .nicotine:
            return "Any nicotine use raises cardiovascular and cancer risk. Stopping is the single highest-leverage move available."
        case .cardio:
            return "Cardiorespiratory fitness is one of the strongest predictors of all-cause mortality. Weekly aerobic minutes and VO2 max trends are what move it."
        case .strength:
            return "Muscle mass and strength protect against falls, frailty, metabolic disease, and loss of independence as you age."
        case .bodyComposition:
            return "Waist circumference and weight trends are practical signals of metabolic risk — more useful than weight alone."
        case .sleep:
            return "Chronic short or inconsistent sleep raises cardiometabolic risk and impairs recovery. Trends matter more than one night."
        case .alcohol:
            return "Alcohol raises blood pressure, sleep fragmentation, and cancer risk. Less is better; none is fine."
        case .protein:
            return "Adequate daily protein supports muscle retention, recovery, and satiety — especially important from middle age onward."
        case .fiber:
            return "Higher dietary fiber lowers cardiovascular and colorectal cancer risk and improves metabolic health."
        case .omega3:
            return "Regular intake of long-chain omega-3 (oily fish) is associated with lower cardiovascular risk."
        case .dental:
            return "Oral health correlates with cardiovascular and systemic inflammation. Low-effort, surfaces only when bigger items are handled."
        }
    }
}

enum DomainStatus: String, Codable {
    case good
    case borderline
    case bad
    case urgent
    case missing
    case unknown

    var displayLabel: String {
        switch self {
        case .good:        "On track"
        case .borderline:  "Borderline"
        case .bad:         "Needs attention"
        case .urgent:      "Urgent"
        case .missing:     "Missing data"
        case .unknown:     "Unknown"
        }
    }
}

enum TrendDirection: String, Codable {
    case improving
    case stable
    case worsening
    case unknown

    var displayLabel: String {
        switch self {
        case .improving:  "Improving"
        case .stable:     "Stable"
        case .worsening:  "Worsening"
        case .unknown:    "—"
        }
    }

    var arrowSymbol: String {
        switch self {
        case .improving:  "arrow.down.right"
        case .stable:     "arrow.right"
        case .worsening:  "arrow.up.right"
        case .unknown:    "questionmark"
        }
    }
}

enum ReminderFrequency: String, Codable, CaseIterable {
    case daily
    case fewDays
    case weekly
    case biweekly
    case monthly
    case quarterly
    case rare
    case never

    var days: Int? {
        switch self {
        case .daily:      1
        case .fewDays:    3
        case .weekly:     7
        case .biweekly:   14
        case .monthly:    30
        case .quarterly:  90
        case .rare:       180
        case .never:      nil
        }
    }

    var displayLabel: String {
        switch self {
        case .daily:      "Daily"
        case .fewDays:    "Every few days"
        case .weekly:     "Weekly"
        case .biweekly:   "Every 2 weeks"
        case .monthly:    "Monthly"
        case .quarterly:  "Every ~3 months"
        case .rare:       "Rarely"
        case .never:      "Off"
        }
    }
}

enum MetricSource: String, Codable {
    case healthKit
    case manual
    case derived
}

enum AlcoholLevel: String, Codable, CaseIterable, Identifiable {
    case none
    case light
    case heavy

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .none:   "None"
        case .light:  "Light"
        case .heavy:  "Heavy"
        }
    }
}
