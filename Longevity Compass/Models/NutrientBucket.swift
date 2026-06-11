import Foundation
import SwiftUI

/// Weekly nutrition signals derived from meal-photo fingerprints.
/// Aim, "behaviour pattern precision, not false gram precision."
enum NutrientBucket: String, CaseIterable, Identifiable {
    case plantVariety
    case leafyGreenDays
    case omega3Days
    case fermentedDays
    case legumeDays
    case ultraProcessedMeals
    case processedMeatMeals
    case friedMeals

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .plantVariety:        "Plant variety"
        case .leafyGreenDays:      "Leafy greens"
        case .omega3Days:          "Omega-3 sources"
        case .fermentedDays:       "Fermented foods"
        case .legumeDays:          "Legumes"
        case .ultraProcessedMeals: "Ultra-processed"
        case .processedMeatMeals:  "Processed meat"
        case .friedMeals:          "Fried"
        }
    }

    var systemImage: String {
        switch self {
        case .plantVariety:        "leaf.circle"
        case .leafyGreenDays:      "leaf"
        case .omega3Days:          "fish"
        case .fermentedDays:       "bubbles.and.sparkles"
        case .legumeDays:          "circle.grid.2x2"
        case .ultraProcessedMeals: "shippingbox"
        case .processedMeatMeals:  "exclamationmark.octagon"
        case .friedMeals:          "flame"
        }
    }

    /// True when the metric should be minimised. We want more plant variety, fewer fried meals.
    var lowerIsBetter: Bool {
        switch self {
        case .ultraProcessedMeals, .processedMeatMeals, .friedMeals: true
        default: false
        }
    }

    /// Per-week target (or upper limit if `lowerIsBetter`).
    var weeklyTarget: Double {
        switch self {
        case .plantVariety:        HealthThresholds.Nutrition.plantsPerWeekTarget
        case .leafyGreenDays:      HealthThresholds.Nutrition.leafyGreenDaysPerWeekTarget
        case .omega3Days:          HealthThresholds.Nutrition.omega3DaysPerWeekTarget
        case .fermentedDays:       HealthThresholds.Nutrition.fermentedDaysPerWeekTarget
        case .legumeDays:          HealthThresholds.Nutrition.legumeDaysPerWeekTarget
        case .ultraProcessedMeals: HealthThresholds.Nutrition.ultraProcessedMealsPerWeekLimit
        case .processedMeatMeals:  HealthThresholds.Nutrition.processedMeatMealsPerWeekLimit
        case .friedMeals:          HealthThresholds.Nutrition.friedMealsPerWeekLimit
        }
    }

    var unitSuffix: String {
        switch self {
        case .plantVariety:        "/wk"
        case .leafyGreenDays, .omega3Days, .fermentedDays, .legumeDays: "d/wk"
        case .ultraProcessedMeals, .processedMeatMeals, .friedMeals:    "/wk"
        }
    }
}

enum BucketStatus: String {
    case veryLow
    case low
    case ok
    case high
    case veryHigh
    case unknown

    var displayLabel: String {
        switch self {
        case .veryLow:  "Very low"
        case .low:      "Low"
        case .ok:       "On target"
        case .high:     "High"
        case .veryHigh: "Very high"
        case .unknown:  "Insufficient data"
        }
    }

    var systemImage: String {
        switch self {
        case .veryLow, .low:    "arrow.down"
        case .ok:               "checkmark"
        case .high, .veryHigh:  "arrow.up"
        case .unknown:          "questionmark"
        }
    }
}
