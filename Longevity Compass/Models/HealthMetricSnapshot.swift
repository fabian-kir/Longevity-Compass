import Foundation
import SwiftData

enum HealthMetricType: String, Codable, CaseIterable {
    case dailyStepsAverage7d
    case exerciseMinutesPerWeek
    case workoutsPerWeek
    case restingHeartRateAverage
    case heartRateVariabilityAverage
    case sleepDurationAverage7d
    case bodyMass
    case waistCircumference
    case vo2Max
    case bloodPressureSystolicAverage
    case bloodPressureDiastolicAverage

    var displayName: String {
        switch self {
        case .dailyStepsAverage7d:           "Daily steps (7d avg)"
        case .exerciseMinutesPerWeek:        "Exercise minutes/week"
        case .workoutsPerWeek:               "Workouts/week"
        case .restingHeartRateAverage:       "Resting heart rate"
        case .heartRateVariabilityAverage:   "Heart rate variability"
        case .sleepDurationAverage7d:        "Sleep (avg)"
        case .bodyMass:                      "Body weight"
        case .waistCircumference:            "Waist circumference"
        case .vo2Max:                        "VO₂ max"
        case .bloodPressureSystolicAverage:  "Systolic (avg)"
        case .bloodPressureDiastolicAverage: "Diastolic (avg)"
        }
    }

    var unit: String {
        switch self {
        case .dailyStepsAverage7d:           "steps"
        case .exerciseMinutesPerWeek:        "min"
        case .workoutsPerWeek:               "/wk"
        case .restingHeartRateAverage:       "bpm"
        case .heartRateVariabilityAverage:   "ms"
        case .sleepDurationAverage7d:        "h"
        case .bodyMass:                      "kg"
        case .waistCircumference:            "cm"
        case .vo2Max:                        "ml/kg/min"
        case .bloodPressureSystolicAverage,
             .bloodPressureDiastolicAverage: "mmHg"
        }
    }
}

@Model
final class HealthMetricSnapshot {
    var id: UUID
    var metricTypeRaw: String
    var value: Double
    var secondaryValue: Double?
    var unit: String
    var sourceRaw: String
    var date: Date

    init(
        id: UUID = UUID(),
        metricType: HealthMetricType,
        value: Double,
        secondaryValue: Double? = nil,
        unit: String? = nil,
        source: MetricSource = .healthKit,
        date: Date = .now
    ) {
        self.id = id
        self.metricTypeRaw = metricType.rawValue
        self.value = value
        self.secondaryValue = secondaryValue
        self.unit = unit ?? metricType.unit
        self.sourceRaw = source.rawValue
        self.date = date
    }

    var metricType: HealthMetricType? { HealthMetricType(rawValue: metricTypeRaw) }
    var source: MetricSource { MetricSource(rawValue: sourceRaw) ?? .derived }
}
