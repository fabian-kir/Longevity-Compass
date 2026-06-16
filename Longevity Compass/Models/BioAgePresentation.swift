import Foundation

// MARK: - Presentation helpers for the bio-age engine
//
// These display-name extensions live outside the engine on purpose: they're a
// UI concern (sheet headers, top-lever sentence) and shouldn't drift the
// engine's responsibility. Keep them lean — only what the bio-age UI reads.

extension BioSignal {
    /// Human-readable name for a signal, used in the "How this was calculated"
    /// sheet and in the top-lever sentence on the bio-age panel.
    var displayName: String {
        switch self {
        case .vo2Max:           return "Cardio fitness (VO2 max)"
        case .rhr:              return "Resting heart rate"
        case .hrv:              return "Heart rate variability"
        case .hba1c:            return "HbA1c"
        case .fastingGlucose:   return "Fasting glucose"
        case .fastingInsulin:   return "HOMA-IR / fasting insulin"
        case .apoB:             return "ApoB"
        case .ldl:              return "LDL-C"
        case .hdl:              return "HDL-C"
        case .trigHdlRatio:     return "TG:HDL ratio"
        case .bloodPressure:    return "Blood pressure"
        case .hsCrp:            return "hs-CRP (inflammation)"
        case .homocysteine:     return "Homocysteine"
        case .eGFR:             return "eGFR (kidney)"
        case .alt:              return "ALT (liver)"
        case .waist:            return "Waist circumference"
        case .weightTrend:      return "Weight trend"
        case .sleep:            return "Sleep"
        case .exerciseMinutes:  return "Weekly exercise"
        case .strengthSessions: return "Strength training"
        case .dailySteps:       return "Daily steps"
        case .nicotine:         return "Nicotine"
        case .alcohol:          return "Alcohol"
        case .nutrition:        return "Diet quality"
        }
    }
}

extension BioSignal {
    /// HealthDomain used for icon rendering in the calculation sheet. Mirrors
    /// the domain values used by the engine's per-signal builders so the icon
    /// shown in the sheet matches what each contributor would otherwise use.
    var presentationDomain: HealthDomain {
        switch self {
        case .vo2Max, .rhr, .hrv, .dailySteps, .exerciseMinutes:
            return .cardio
        case .hba1c, .fastingGlucose, .fastingInsulin,
             .apoB, .ldl, .hdl, .trigHdlRatio,
             .hsCrp, .homocysteine,
             .eGFR, .alt:
            return .bloodwork
        case .bloodPressure:
            return .bloodPressure
        case .waist, .weightTrend:
            return .bodyComposition
        case .sleep:
            return .sleep
        case .strengthSessions:
            return .strength
        case .nutrition:
            return .fiber
        case .nicotine:
            return .nicotine
        case .alcohol:
            return .alcohol
        }
    }
}

extension BioFactor {
    /// Section title shown in the "How this was calculated" sheet, one per
    /// factor with at least one non-suppressed reading.
    var displayName: String {
        switch self {
        case .fitness:      return "Cardio fitness"
        case .glycemic:     return "Metabolic / glycemic"
        case .lipids:       return "Lipids"
        case .hemodynamic:  return "Blood pressure"
        case .bodyComp:     return "Body composition"
        case .inflammation: return "Inflammation"
        case .organ:        return "Organ function"
        case .behavior:     return "Lifestyle"
        case .nicotine:     return "Nicotine"
        case .alcohol:      return "Alcohol"
        }
    }

    /// Stable display order for factor sections in the sheet. Earlier =
    /// shown first.
    var displayOrder: Int {
        switch self {
        case .fitness:      return 0
        case .glycemic:     return 1
        case .lipids:       return 2
        case .hemodynamic:  return 3
        case .bodyComp:     return 4
        case .inflammation: return 5
        case .organ:        return 6
        case .behavior:     return 7
        case .nicotine:     return 8
        case .alcohol:      return 9
        }
    }
}
