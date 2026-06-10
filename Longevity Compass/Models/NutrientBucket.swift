import Foundation
import SwiftUI

enum NutrientBucket: String, CaseIterable, Identifiable {
    case protein
    case fiber
    case addedSugar
    case saturatedFat
    case sodium
    case fattyFish
    case leafyGreens
    case ultraProcessed
    case eatingOccasions

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .protein:          "Protein"
        case .fiber:            "Fibre"
        case .addedSugar:       "Added sugar"
        case .saturatedFat:     "Saturated fat"
        case .sodium:           "Sodium"
        case .fattyFish:        "Fatty fish"
        case .leafyGreens:      "Leafy greens"
        case .ultraProcessed:   "Ultra-processed"
        case .eatingOccasions:  "Eating occasions"
        }
    }

    var systemImage: String {
        switch self {
        case .protein:          "fork.knife"
        case .fiber:            "leaf"
        case .addedSugar:       "cube"
        case .saturatedFat:     "drop"
        case .sodium:           "drop.triangle"
        case .fattyFish:        "fish"
        case .leafyGreens:      "carrot"
        case .ultraProcessed:   "shippingbox"
        case .eatingOccasions:  "clock"
        }
    }

    /// True when the metric should be minimised (e.g., added sugar, sodium).
    var lowerIsBetter: Bool {
        switch self {
        case .addedSugar, .saturatedFat, .sodium, .ultraProcessed: true
        case .eatingOccasions: true  // we treat constant snacking as worse
        default: false
        }
    }

    var unitSuffix: String {
        switch self {
        case .protein, .fiber, .addedSugar, .saturatedFat:  "g/day"
        case .sodium:                                       "mg/day"
        case .fattyFish:                                    "/week"
        case .leafyGreens:                                  "/day"
        case .ultraProcessed:                               ""
        case .eatingOccasions:                              "/day"
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
