#if DEBUG
import Foundation
import HealthKit

/// Profile-based sanity harness for `BiologicalAgeEngine`.
///
/// There is no XCTest target in this project; instead these are synthetic
/// "representative user" profiles whose engine output is asserted via
/// `precondition` so regressions trip the harness loudly in DEBUG builds.
///
/// Invoke explicitly via `BioAgeProfileTests.runAll()` (e.g. from app init in
/// DEBUG) — the harness is intentionally NOT wired into `evaluate(...)`.
///
/// The numeric bounds are deliberately wide — the harness validates the engine
/// lands in the right neighbourhood for each profile, not a pinned exact value.
enum BioAgeProfileTests {

    /// Run every profile sanity test. Each profile prints a marker line on
    /// success; any failing precondition aborts with a profile-named message.
    static func runAll(now: Date = Date()) {
        runEliteEndurance40M(now: now)
        runMetabolicSyndrome45MNoBloodwork(now: now)
        runMetabolicSyndrome45MWithBloodwork(now: now)
        runVeganLightDrinkerLowExerciseData(now: now)
        print("[BioAge] All profile tests passed.")
    }

    // MARK: - Profile A: Elite endurance 40M

    /// Watch-rich athlete with clean bloodwork. Expectation: substantially
    /// younger than chronological, high confidence, no major "top lever".
    static func runEliteEndurance40M(now: Date = Date()) {
        let profile = "Profile A — Elite endurance 40M"
        let dob = yearsAgo(40, from: now)

        var snapshot = HealthKitSnapshot()
        snapshot.dateOfBirth = dob
        snapshot.biologicalSex = .male
        snapshot.latestVO2Max = (value: 55, date: daysAgo(45, from: now))
        snapshot.restingHeartRateAverage28d = 48
        // Empty series → engine treats RHR freshness as 1.0 (the "<14 day"
        // halving rule only fires for non-empty short series).
        snapshot.restingHeartRateSeries = []
        snapshot.hrvAverage28d = 65
        snapshot.sleepHoursAverage7d = 8.0
        snapshot.exerciseMinutesPerWeek = 360
        snapshot.strengthWorkoutsLast7Days = 3
        snapshot.latestBodyMass = (value: 75, date: daysAgo(1, from: now))
        // Weight-stable: needs >= weightSeriesMinPoints (6) points across the
        // 90d window; supply 7 near-identical samples.
        snapshot.bodyMassSeries = (0..<7).map { i in
            (date: daysAgo(90 - i * 12, from: now), value: 75.0)
        }

        let manualEntries: [ManualEntry] = [
            ManualEntry(entryType: .waist, date: daysAgo(7, from: now), primaryValue: 82),
        ]

        let panel = BloodworkPanel(
            date: daysAgo(30, from: now),
            markers: [
                BloodworkMarker(name: "HbA1c",         value: "5.0", unit: "%",     flag: .good),
                BloodworkMarker(name: "ApoB",          value: "75",  unit: "mg/dL", flag: .good),
                BloodworkMarker(name: "hs-CRP",        value: "0.6", unit: "mg/L",  flag: .good),
                BloodworkMarker(name: "HDL-C",         value: "60",  unit: "mg/dL", flag: .good),
                BloodworkMarker(name: "Triglycerides", value: "80",  unit: "mg/dL", flag: .good),
                BloodworkMarker(name: "eGFR",          value: "100", unit: "mL/min", flag: .good),
            ]
        )

        guard let estimate = BiologicalAgeEngine.evaluate(
            manualEntries: manualEntries,
            nutritionDigest: nil,
            healthSnapshot: snapshot,
            bloodworkPanels: [panel],
            now: now
        ) else {
            preconditionFailure("[\(profile)] evaluate(...) returned nil")
        }

        // 1. delta in expected (younger) range.
        precondition(
            estimate.delta >= -8.0 && estimate.delta <= -3.0,
            "[\(profile)] expected delta in [-8.0, -3.0], got \(estimate.delta)"
        )

        // 2. confidence is high — bloodwork + watch all present.
        precondition(
            estimate.confidence >= 0.7,
            "[\(profile)] expected confidence >= 0.7, got \(estimate.confidence)"
        )

        // 3. topLever should be nil OR carry a small potential (this user has
        //    no meaningful weakness lever to push).
        if let lever = estimate.topLever, let yps = lever.signal.yearsPerSD {
            let potential = abs(lever.zScore * yps)
            precondition(
                potential < 1.0,
                "[\(profile)] expected topLever to be nil or low magnitude (<1y), got \(lever.signal) at \(potential)y"
            )
        }
    }

    // MARK: - Profile B: Metabolic syndrome 45M, no bloodwork

    /// Watch-only, no bloodwork. Multiple behavior + flat-penalty signals
    /// stack to push bio-age substantially older with moderate confidence.
    static func runMetabolicSyndrome45MNoBloodwork(now: Date = Date()) {
        let profile = "Profile B — Metabolic syndrome 45M no bloodwork"
        let dob = yearsAgo(45, from: now)

        var snapshot = HealthKitSnapshot()
        snapshot.dateOfBirth = dob
        snapshot.biologicalSex = .male
        snapshot.latestVO2Max = (value: 28, date: daysAgo(30, from: now))
        snapshot.restingHeartRateAverage28d = 78
        snapshot.restingHeartRateSeries = []
        snapshot.hrvAverage28d = 22
        snapshot.sleepHoursAverage7d = 5.5
        snapshot.exerciseMinutesPerWeek = 30
        snapshot.strengthWorkoutsLast7Days = 0

        let manualEntries: [ManualEntry] = [
            ManualEntry(entryType: .waist, date: daysAgo(7, from: now), primaryValue: 108),
            ManualEntry(entryType: .nicotine, date: daysAgo(3, from: now), booleanValue: true),
            ManualEntry(entryType: .alcohol, date: daysAgo(1, from: now),  categorical: AlcoholLevel.heavy.rawValue),
            ManualEntry(entryType: .alcohol, date: daysAgo(5, from: now),  categorical: AlcoholLevel.heavy.rawValue),
            ManualEntry(entryType: .alcohol, date: daysAgo(9, from: now),  categorical: AlcoholLevel.heavy.rawValue),
        ]

        guard let estimate = BiologicalAgeEngine.evaluate(
            manualEntries: manualEntries,
            nutritionDigest: nil,
            healthSnapshot: snapshot,
            bloodworkPanels: [],
            now: now
        ) else {
            preconditionFailure("[\(profile)] evaluate(...) returned nil")
        }

        // 1. delta in expected older range.
        precondition(
            estimate.delta >= 8.0 && estimate.delta <= 18.0,
            "[\(profile)] expected delta in [8.0, 18.0], got \(estimate.delta)"
        )

        // 2. moderate confidence — watch signals present, no bloodwork.
        precondition(
            estimate.confidence >= 0.3 && estimate.confidence <= 0.6,
            "[\(profile)] expected confidence in [0.3, 0.6], got \(estimate.confidence)"
        )

        // 3. topLever should be present and point at a behavior factor.
        guard let lever = estimate.topLever else {
            preconditionFailure("[\(profile)] expected non-nil topLever")
        }
        let acceptable: Set<BioSignal> = [.exerciseMinutes, .sleep, .nutrition]
        precondition(
            acceptable.contains(lever.signal),
            "[\(profile)] expected topLever in \(acceptable), got \(lever.signal)"
        )
    }

    // MARK: - Profile C: Metabolic syndrome 45M WITH bloodwork

    /// Same metabolic profile as B but with a fresh bloodwork panel showing
    /// elevated HbA1c / ApoB / hs-CRP / triglycerides. Verifies Layer A
    /// correctly marks sleep + nutrition as suppressed by the fresh
    /// downstream signals, and that delta stacks even further.
    static func runMetabolicSyndrome45MWithBloodwork(now: Date = Date()) {
        let profile = "Profile C — Metabolic syndrome 45M with bloodwork"
        let dob = yearsAgo(45, from: now)

        var snapshot = HealthKitSnapshot()
        snapshot.dateOfBirth = dob
        snapshot.biologicalSex = .male
        snapshot.latestVO2Max = (value: 28, date: daysAgo(30, from: now))
        snapshot.restingHeartRateAverage28d = 78
        snapshot.restingHeartRateSeries = []
        snapshot.hrvAverage28d = 22
        snapshot.sleepHoursAverage7d = 5.5
        snapshot.exerciseMinutesPerWeek = 30
        snapshot.strengthWorkoutsLast7Days = 0

        let manualEntries: [ManualEntry] = [
            ManualEntry(entryType: .waist, date: daysAgo(7, from: now), primaryValue: 108),
            ManualEntry(entryType: .nicotine, date: daysAgo(3, from: now), booleanValue: true),
            ManualEntry(entryType: .alcohol, date: daysAgo(1, from: now),  categorical: AlcoholLevel.heavy.rawValue),
            ManualEntry(entryType: .alcohol, date: daysAgo(5, from: now),  categorical: AlcoholLevel.heavy.rawValue),
            ManualEntry(entryType: .alcohol, date: daysAgo(9, from: now),  categorical: AlcoholLevel.heavy.rawValue),
        ]

        // Synthetic nutrition digest with 2 unfavorable buckets at high status
        // and no favorable rollups. Engine emits a nutrition reading with
        // score = good - bad = -2, which Layer A then suppresses because
        // fresh hs-CRP / ApoB / HbA1c are present.
        let nutritionDigest = NutritionDigest(
            rollups: [
                makeRollup(.ultraProcessedMeals, status: .high),
                makeRollup(.friedMeals,          status: .high),
            ],
            coverageDays: 14,
            lookbackDays: 14,
            totalEntries: 14,
            costThisMonthUSD: 0,
            costAllTimeUSD: 0
        )

        let panel = BloodworkPanel(
            date: daysAgo(30, from: now),
            markers: [
                BloodworkMarker(name: "HbA1c",         value: "6.1", unit: "%",     flag: .borderline),
                BloodworkMarker(name: "ApoB",          value: "130", unit: "mg/dL", flag: .bad),
                BloodworkMarker(name: "hs-CRP",        value: "4.5", unit: "mg/L",  flag: .bad),
                BloodworkMarker(name: "eGFR",          value: "90",  unit: "mL/min", flag: .good),
                BloodworkMarker(name: "HDL-C",         value: "38",  unit: "mg/dL", flag: .borderline),
                BloodworkMarker(name: "Triglycerides", value: "220", unit: "mg/dL", flag: .bad),
            ]
        )

        guard let estimate = BiologicalAgeEngine.evaluate(
            manualEntries: manualEntries,
            nutritionDigest: nutritionDigest,
            healthSnapshot: snapshot,
            bloodworkPanels: [panel],
            now: now
        ) else {
            preconditionFailure("[\(profile)] evaluate(...) returned nil")
        }

        // 1. delta stacks higher than profile B with multiple bad markers.
        precondition(
            estimate.delta >= 12.0 && estimate.delta <= 25.0,
            "[\(profile)] expected delta in [12.0, 25.0], got \(estimate.delta)"
        )

        // 2. confidence is high — bloodwork + watch + behaviors all present.
        precondition(
            estimate.confidence >= 0.6,
            "[\(profile)] expected confidence >= 0.6, got \(estimate.confidence)"
        )

        // 3. Layer A: sleep should be in readings with suppressedByDownstream
        //    = true (fresh HbA1c trips its glycemic dependency).
        let sleepReading = estimate.readings.first { $0.signal == .sleep }
        precondition(
            sleepReading != nil,
            "[\(profile)] expected a .sleep reading in readings"
        )
        precondition(
            sleepReading?.suppressedByDownstream == true,
            "[\(profile)] expected .sleep to be suppressedByDownstream by fresh bloodwork"
        )

        // 4. Layer A: nutrition should be in readings with suppressedByDownstream
        //    = true (fresh HbA1c / hsCRP / ApoB trip its dependencies).
        let nutritionReading = estimate.readings.first { $0.signal == .nutrition }
        precondition(
            nutritionReading != nil,
            "[\(profile)] expected a .nutrition reading in readings"
        )
        precondition(
            nutritionReading?.suppressedByDownstream == true,
            "[\(profile)] expected .nutrition to be suppressedByDownstream by fresh bloodwork"
        )

        // 5. topLever surfaces a suppressed-but-actionable behavior. Engine's
        //    tie-break / multiCause logic picks either sleep or nutrition.
        guard let lever = estimate.topLever else {
            preconditionFailure("[\(profile)] expected non-nil topLever")
        }
        let acceptable: Set<BioSignal> = [.sleep, .nutrition]
        precondition(
            acceptable.contains(lever.signal),
            "[\(profile)] expected topLever in \(acceptable), got \(lever.signal)"
        )
    }

    // MARK: - Profile D: Vegan light-drinker, no exercise data, no bloodwork

    /// Sparse-signal user: no watch, no bloodwork, only sleep + steps +
    /// light alcohol. Should land on-par with chronological age at low
    /// confidence and have no surfaced top lever.
    static func runVeganLightDrinkerLowExerciseData(now: Date = Date()) {
        let profile = "Profile D — Vegan light-drinker low data"
        let dob = yearsAgo(35, from: now)

        var snapshot = HealthKitSnapshot()
        snapshot.dateOfBirth = dob
        snapshot.biologicalSex = .female
        snapshot.latestVO2Max = nil
        snapshot.restingHeartRateAverage28d = nil
        snapshot.hrvAverage28d = nil
        snapshot.sleepHoursAverage7d = 7.5
        snapshot.exerciseMinutesPerWeek = nil
        snapshot.dailyStepsAverage28d = 9000
        snapshot.strengthWorkoutsLast7Days = nil

        let manualEntries: [ManualEntry] = [
            ManualEntry(entryType: .alcohol, date: daysAgo(2, from: now),  categorical: AlcoholLevel.light.rawValue),
            ManualEntry(entryType: .alcohol, date: daysAgo(8, from: now),  categorical: AlcoholLevel.light.rawValue),
        ]

        guard let estimate = BiologicalAgeEngine.evaluate(
            manualEntries: manualEntries,
            nutritionDigest: nil,
            healthSnapshot: snapshot,
            bloodworkPanels: [],
            now: now
        ) else {
            preconditionFailure("[\(profile)] evaluate(...) returned nil")
        }

        // 1. delta near zero — sleep at typical + steps slightly above typical.
        precondition(
            estimate.delta >= -2.0 && estimate.delta <= 2.0,
            "[\(profile)] expected delta in [-2.0, 2.0], got \(estimate.delta)"
        )

        // 2. confidence is low — very few signals.
        precondition(
            estimate.confidence <= 0.4,
            "[\(profile)] expected confidence <= 0.4, got \(estimate.confidence)"
        )

        // 3. topLever is nil OR very small magnitude (user has no real lever).
        if let lever = estimate.topLever, let yps = lever.signal.yearsPerSD {
            let potential = abs(lever.zScore * yps)
            precondition(
                potential < 1.0,
                "[\(profile)] expected topLever to be nil or low magnitude (<1y), got \(lever.signal) at \(potential)y"
            )
        }
    }

    // MARK: - Helpers

    private static func yearsAgo(_ years: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .year, value: -years, to: date) ?? date
    }

    private static func daysAgo(_ days: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: date) ?? date
    }

    /// Build a NutritionBucketRollup with just the fields the engine reads
    /// (bucket + status). The other fields are filled with neutral values
    /// since the engine's nutrition contributor only inspects `status`.
    private static func makeRollup(_ bucket: NutrientBucket, status: BucketStatus) -> NutritionBucketRollup {
        NutritionBucketRollup(
            bucket: bucket,
            status: status,
            weeklyValue: 0,
            target: 0,
            percentOfTarget: nil,
            daysWithData: 14,
            lookbackDays: 14,
            summary: ""
        )
    }
}
#endif
