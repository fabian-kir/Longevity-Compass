import XCTest
import HealthKit
@testable import Longevity_Compass

/// Profile-based sanity tests for `BiologicalAgeEngine`.
///
/// Four synthetic "representative user" profiles whose engine output is
/// asserted against deliberately wide numeric bounds — the goal is to detect
/// regressions in the neighbourhood the engine should land in, not to pin
/// exact values.
final class BioAgeProfileTests: XCTestCase {

    private let now = Date()

    // MARK: - Profile A: Elite endurance 40M

    /// Watch-rich athlete with clean bloodwork. Expectation: substantially
    /// younger than chronological, high confidence, no major "top lever".
    func testEliteEndurance40M() {
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
        snapshot.hrvSampleCount28d = 28   // full 28d coverage → freshness 1.0
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
            XCTFail("evaluate(...) returned nil")
            return
        }

        // 1. delta in expected (younger) range.
        XCTAssertGreaterThanOrEqual(estimate.delta, -12.0, "delta below floor")
        XCTAssertLessThanOrEqual(estimate.delta, -3.0, "delta above ceiling")

        // 2. confidence is high — bloodwork + watch all present.
        XCTAssertGreaterThanOrEqual(estimate.confidence, 0.7)

        // 3. topLever should be nil OR carry a small potential (this user has
        //    no meaningful weakness lever to push).
        if let lever = estimate.topLever, let yps = lever.signal.yearsPerSD {
            let potential = abs(lever.zScore * yps)
            XCTAssertLessThan(potential, 1.0,
                "expected topLever nil or low magnitude, got \(lever.signal) at \(potential)y")
        }
    }

    // MARK: - Profile B: Metabolic syndrome 45M, no bloodwork

    /// Watch-only, no bloodwork. Multiple behavior + flat-penalty signals
    /// stack to push bio-age substantially older with moderate confidence.
    func testMetabolicSyndrome45M_NoBloodwork() {
        let dob = yearsAgo(45, from: now)

        var snapshot = HealthKitSnapshot()
        snapshot.dateOfBirth = dob
        snapshot.biologicalSex = .male
        snapshot.latestVO2Max = (value: 28, date: daysAgo(30, from: now))
        snapshot.restingHeartRateAverage28d = 78
        snapshot.restingHeartRateSeries = []
        snapshot.hrvAverage28d = 22
        snapshot.hrvSampleCount28d = 28
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
            XCTFail("evaluate(...) returned nil")
            return
        }

        // 1. delta in expected older range.
        XCTAssertGreaterThanOrEqual(estimate.delta, 8.0)
        XCTAssertLessThanOrEqual(estimate.delta, 18.0)

        // 2. moderate confidence — watch signals present, no bloodwork.
        XCTAssertGreaterThanOrEqual(estimate.confidence, 0.3)
        XCTAssertLessThanOrEqual(estimate.confidence, 0.6)

        // 3. topLever should be present and point at a behavior factor.
        guard let lever = estimate.topLever else {
            XCTFail("expected non-nil topLever")
            return
        }
        let acceptable: Set<BioSignal> = [.exerciseMinutes, .sleep, .nutrition]
        XCTAssertTrue(acceptable.contains(lever.signal),
            "expected topLever in \(acceptable), got \(lever.signal)")
    }

    // MARK: - Profile C: Metabolic syndrome 45M WITH bloodwork

    /// Same metabolic profile as B but with a fresh bloodwork panel showing
    /// elevated HbA1c / ApoB / hs-CRP / triglycerides. Verifies Layer A
    /// correctly marks sleep + nutrition as suppressed by the fresh
    /// downstream signals, and that delta stacks even further.
    func testMetabolicSyndrome45M_WithBloodwork() {
        let dob = yearsAgo(45, from: now)

        var snapshot = HealthKitSnapshot()
        snapshot.dateOfBirth = dob
        snapshot.biologicalSex = .male
        snapshot.latestVO2Max = (value: 28, date: daysAgo(30, from: now))
        snapshot.restingHeartRateAverage28d = 78
        snapshot.restingHeartRateSeries = []
        snapshot.hrvAverage28d = 22
        snapshot.hrvSampleCount28d = 28
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
            XCTFail("evaluate(...) returned nil")
            return
        }

        // 1. delta stacks higher than profile B with multiple bad markers.
        XCTAssertGreaterThanOrEqual(estimate.delta, 12.0)
        XCTAssertLessThanOrEqual(estimate.delta, 25.0)

        // 2. confidence is high — bloodwork + watch + behaviors all present.
        XCTAssertGreaterThanOrEqual(estimate.confidence, 0.6)

        // 3. Layer A: sleep should be in readings with suppressedByDownstream
        //    = true (fresh HbA1c trips its glycemic dependency).
        let sleepReading = estimate.readings.first { $0.signal == .sleep }
        XCTAssertNotNil(sleepReading, "expected a .sleep reading in readings")
        XCTAssertEqual(sleepReading?.suppressedByDownstream, true,
            "expected .sleep to be suppressedByDownstream by fresh bloodwork")

        // 4. Layer A: nutrition should be in readings with suppressedByDownstream
        //    = true (fresh HbA1c / hsCRP / ApoB trip its dependencies).
        let nutritionReading = estimate.readings.first { $0.signal == .nutrition }
        XCTAssertNotNil(nutritionReading, "expected a .nutrition reading in readings")
        XCTAssertEqual(nutritionReading?.suppressedByDownstream, true,
            "expected .nutrition to be suppressedByDownstream by fresh bloodwork")

        // 5. topLever surfaces a suppressed-but-actionable behavior. Engine's
        //    tie-break / multiCause logic picks either sleep or nutrition.
        guard let lever = estimate.topLever else {
            XCTFail("expected non-nil topLever")
            return
        }
        let acceptable: Set<BioSignal> = [.sleep, .nutrition]
        XCTAssertTrue(acceptable.contains(lever.signal),
            "expected topLever in \(acceptable), got \(lever.signal)")
    }

    // MARK: - Profile D: Vegan light-drinker, no exercise data, no bloodwork

    /// Sparse-signal user: no watch, no bloodwork, only sleep + steps +
    /// light alcohol. Should land on-par with chronological age at low
    /// confidence and have no surfaced top lever.
    func testVeganLightDrinker_LowExerciseData() {
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
            XCTFail("evaluate(...) returned nil")
            return
        }

        // 1. delta near zero — sleep at typical + steps slightly above typical.
        XCTAssertGreaterThanOrEqual(estimate.delta, -2.0)
        XCTAssertLessThanOrEqual(estimate.delta, 2.0)

        // 2. confidence is low — very few signals.
        XCTAssertLessThanOrEqual(estimate.confidence, 0.4)

        // 3. topLever is nil OR very small magnitude (user has no real lever).
        if let lever = estimate.topLever, let yps = lever.signal.yearsPerSD {
            let potential = abs(lever.zScore * yps)
            XCTAssertLessThan(potential, 1.0,
                "expected topLever nil or low magnitude, got \(lever.signal) at \(potential)y")
        }
    }

    // MARK: - Helpers

    private func yearsAgo(_ years: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .year, value: -years, to: date) ?? date
    }

    private func daysAgo(_ days: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: date) ?? date
    }

    /// Build a NutritionBucketRollup with just the fields the engine reads
    /// (bucket + status). Other fields filled with neutral values since the
    /// nutrition contributor only inspects `status`.
    private func makeRollup(_ bucket: NutrientBucket, status: BucketStatus) -> NutritionBucketRollup {
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
