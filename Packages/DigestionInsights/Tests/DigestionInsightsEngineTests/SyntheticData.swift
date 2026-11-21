import Foundation
@testable import DigestionInsightsEngine

/// 2026-01-01 00:00 UTC, an exact hour.
let day0 = Date(timeIntervalSince1970: 1_767_225_600)

func hoursAfterDay0(_ hours: Double) -> Date {
    day0.addingTimeInterval(hours * 3600)
}

/// Minimal deterministic generator for engine tests (the full simulation
/// generator with logging behaviour lives in unit 4's code).
struct SyntheticScenario {
    struct Trigger {
        var feature: String
        var kind: String
        /// Lag hours [lower, upper) during which the rate is multiplied.
        var lagRange: Range<Double>
        var multiplier: Double
    }

    var days: Int
    var mealHours: [Double] = [8, 13, 19]
    /// Feature ID and probability of appearing in a meal.
    var features: [(id: String, probability: Double)]
    var kinds: [String]
    /// Baseline symptoms per day, per kind.
    var baselinePerDay: [Double]
    var trigger: Trigger?
    var seed: UInt64

    func makeInput(config: AnalysisConfig) -> AnalysisInput {
        var rng = Xoshiro256StarStar(seed: seed)
        var exposures: [ExposureEvent] = []
        for day in 0..<days {
            for mealHour in mealHours {
                let time = Double(day) * 24 + mealHour + rng.uniform(in: -0.5, 0.5)
                for feature in features where rng.uniform() < feature.probability {
                    exposures.append(ExposureEvent(featureID: feature.id, time: hoursAfterDay0(time), value: 1))
                }
            }
        }
        let triggerTimes = trigger.map { trigger in
            exposures.filter { $0.featureID == trigger.feature }.map { $0.time.timeIntervalSince(day0) / 3600 }
        } ?? []
        var symptoms: [SymptomEvent] = []
        for hour in 0..<(days * 24) {
            let centre = Double(hour) + 0.5
            for (s, kind) in kinds.enumerated() {
                var rate = baselinePerDay[s] / 24
                if let trigger, trigger.kind == kind,
                   triggerTimes.contains(where: { trigger.lagRange.contains(centre - $0) }) {
                    rate *= trigger.multiplier
                }
                for _ in 0..<poisson(rate, &rng) {
                    symptoms.append(SymptomEvent(
                        kind: kind,
                        onset: hoursAfterDay0(Double(hour) + rng.uniform()),
                        levelRank: 0,
                        isTopLevel: false
                    ))
                }
            }
        }
        return AnalysisInput(
            exposures: exposures,
            symptoms: symptoms,
            windows: [ObservationWindow(start: day0, end: hoursAfterDay0(Double(days * 24)))],
            symptomKinds: kinds,
            config: config
        )
    }

    /// Knuth's multiplication method; fine for the small rates used here.
    private func poisson(_ lambda: Double, _ rng: inout Xoshiro256StarStar) -> Int {
        let limit = exp(-lambda)
        var count = 0
        var product = rng.uniform()
        while product > limit {
            count += 1
            product *= rng.uniform()
        }
        return count
    }
}

/// Small sampler settings for CI-speed model tests.
func fastConfig(seed: UInt64 = 1, warmup: Int = 300, samples: Int = 300) -> AnalysisConfig {
    AnalysisConfig(warmup: warmup, samples: samples, seed: seed, chartDraws: 50)
}
