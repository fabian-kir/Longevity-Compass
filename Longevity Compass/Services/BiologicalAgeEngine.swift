import Foundation
import HealthKit

// MARK: - New Type Scaffolding (Task 1 — pure additive, not yet wired into evaluate())

/// Individual measurable signals that feed into the biological-age engine.
/// Each signal maps to exactly one `BioFactor` (see `BioSignal.factor`).
enum BioSignal: String, CaseIterable, Hashable {
    case vo2Max, rhr, hrv
    case hba1c, fastingGlucose, fastingInsulin
    case apoB, ldl, hdl, trigHdlRatio
    case bloodPressure
    case hsCrp, homocysteine
    case eGFR, alt
    case waist, weightTrend
    case sleep, exerciseMinutes, strengthSessions, dailySteps
    case nicotine, alcohol, nutrition

    /// Whether a higher raw value is healthier (e.g. VO2 max) or a lower raw
    /// value is healthier (e.g. ApoB). Used by the aggregator to orient the
    /// z-score sign consistently across signals.
    var direction: BioDirection {
        switch self {
        case .vo2Max, .hrv, .hdl, .eGFR, .dailySteps, .exerciseMinutes,
             .strengthSessions, .sleep, .nutrition:
            return .higherIsBetter
        case .rhr, .hba1c, .fastingGlucose, .fastingInsulin, .apoB, .ldl,
             .trigHdlRatio, .bloodPressure, .hsCrp, .homocysteine, .alt,
             .waist, .weightTrend, .nicotine, .alcohol:
            return .lowerIsBetter
        }
    }

    /// The higher-level `BioFactor` group this signal belongs to. Making this
    /// computed (rather than a separately-stored field on `BioInputReading`)
    /// enforces the invariant that every signal has exactly one factor.
    var factor: BioFactor {
        switch self {
        case .vo2Max, .rhr, .hrv:
            return .fitness
        case .hba1c, .fastingGlucose, .fastingInsulin:
            return .glycemic
        case .apoB, .ldl, .hdl, .trigHdlRatio:
            return .lipids
        case .bloodPressure:
            return .hemodynamic
        case .waist, .weightTrend:
            return .bodyComp
        case .hsCrp, .homocysteine:
            return .inflammation
        case .eGFR, .alt:
            return .organ
        case .sleep, .exerciseMinutes, .strengthSessions, .dailySteps, .nutrition:
            return .behavior
        case .nicotine:
            return .nicotine
        case .alcohol:
            return .alcohol
        }
    }
}

/// Higher-level grouping a signal belongs to. Used by Layer A logic (later tasks)
/// to apply intra-factor caps and downstream suppression.
enum BioFactor: String, CaseIterable, Hashable {
    case fitness        // VO2, RHR, HRV
    case glycemic       // HbA1c, fasting glucose, fasting insulin
    case lipids         // ApoB/LDL, HDL, TG:HDL
    case hemodynamic    // BP
    case bodyComp       // waist, weight trend
    case inflammation   // hs-CRP, homocysteine
    case organ          // eGFR, ALT
    case behavior       // sleep, exercise, strength, steps, nutrition
    case nicotine       // always contributes; never suppressed by Layer A
    case alcohol        // always contributes; never suppressed by Layer A
}

/// Direction of "better" for a signal — does a higher raw value mean healthier
/// (e.g. VO2 max) or does a lower raw value mean healthier (e.g. ApoB)?
enum BioDirection {
    case higherIsBetter
    case lowerIsBetter
}

/// A single normalized input feeding the bio-age aggregator. Built once per
/// signal, then potentially marked `suppressedByDownstream` by Layer A.
struct BioInputReading: Hashable {
    let signal: BioSignal
    let value: Double
    let referenceMean: Double      // age/sex-anchored typical value
    let referenceSD: Double
    /// Signed: + = better than typical. Note that the engine flips the sign
    /// when computing `rawYearsImpact` — a positive z-score yields negative
    /// years (younger), and vice versa.
    let zScore: Double
    let rawYearsImpact: Double      // z × yearsPerSD (sign-flipped), before cap & suppression
    let freshnessWeight: Double     // 0...1
    let qualityWeight: Double       // 0...1
    /// Set later by Layer A logic (Task 5). Mutable so Layer A can flip it
    /// in place on this value-type struct without reconstructing the whole
    /// reading. Default false at construction time.
    var suppressedByDownstream: Bool

    /// Factor membership is derived from `signal` so a reading can never be
    /// constructed with a mismatched signal/factor pair.
    var factor: BioFactor { signal.factor }

    var effectiveWeight: Double { freshnessWeight * qualityWeight }
}

// MARK: - V2 Logic Helpers (Task 2 — pure math; aggregator wires them up in Task 3)

extension BioInputReading {
    /// Direction-agnostic z-score. Returns a SIGNED z where `+` always means
    /// "better than typical".
    ///
    /// - For `.higherIsBetter`: `(value - mean) / sd`
    /// - For `.lowerIsBetter`:  `(mean - value) / sd`
    /// - If `sd == 0`, returns 0 as a safeguard.
    static func zScore(value: Double, mean: Double, sd: Double, direction: BioDirection) -> Double {
        guard sd > 0 else { return 0 }
        switch direction {
        case .higherIsBetter: return (value - mean) / sd
        case .lowerIsBetter:  return (mean - value) / sd
        }
    }
}

/// Linearly interpolate a decade-keyed reference table (e.g. age → norm).
///
/// Keys are expected to be decade floors (20, 30, 40, …). For an age that
/// falls between two adjacent decade keys, interpolates linearly. Ages below
/// the smallest key clamp to that key's value; ages above the largest key
/// clamp to that key's value. Returns 0 if the table is empty.
func interpolateDecadeNorm(age: Double, table: [Int: Double]) -> Double {
    let keys = table.keys.sorted()
    guard let first = keys.first, let last = keys.last else { return 0 }
    if keys.count == 1 { return table[keys[0]] ?? 0 }
    if age <= Double(first) { return table[first] ?? 0 }
    if age >= Double(last)  { return table[last]  ?? 0 }
    // Find the two adjacent decade keys bracketing `age`.
    for i in 0..<(keys.count - 1) {
        let lo = keys[i]
        let hi = keys[i + 1]
        if age >= Double(lo) && age <= Double(hi) {
            let loV = table[lo] ?? 0
            let hiV = table[hi] ?? 0
            let span = Double(hi - lo)
            guard span > 0 else { return loV }
            let t = (age - Double(lo)) / span
            return loV + (hiV - loV) * t
        }
    }
    preconditionFailure("interpolateDecadeNorm fell through clamp logic")
}

extension BioSignal {
    /// Years-per-standard-deviation weight used in z-score scaling.
    /// Returns nil for signals handled as flat penalties (nicotine, alcohol),
    /// which never participate in z-score math.
    var yearsPerSD: Double? {
        switch self {
        case .nicotine, .alcohol: return nil
        case .vo2Max:           return 2.0
        case .rhr:              return 1.0
        case .hrv:              return 0.8
        case .hba1c:            return 2.5
        case .fastingGlucose:   return 1.5
        case .fastingInsulin:   return 1.5
        case .apoB:             return 2.5
        case .ldl:              return 1.5
        case .hdl:              return 0.8
        case .trigHdlRatio:     return 1.2
        case .bloodPressure:    return 2.0
        case .hsCrp:            return 1.5
        case .homocysteine:     return 0.6
        case .eGFR:             return 1.0
        case .alt:              return 0.6
        case .waist:            return 1.5
        case .weightTrend:      return 0.5
        case .sleep:            return 1.0
        case .exerciseMinutes:  return 1.0
        case .strengthSessions: return 0.6
        case .dailySteps:       return 0.4
        case .nutrition:        return 0.5
        }
    }
}

extension BioFactor {
    /// Maximum absolute years-impact a single factor's combined signals may
    /// contribute. For nicotine/alcohol the cap also represents the magnitude
    /// ceiling of the flat penalty (sign handled by the aggregator).
    var yearsCap: Double {
        switch self {
        case .fitness:      return 6
        case .glycemic:     return 5
        case .lipids:       return 5
        case .hemodynamic:  return 5
        case .bodyComp:     return 4
        case .inflammation: return 4
        case .organ:        return 3
        case .behavior:     return 6
        case .nicotine:     return 5   // +5/-1 ceiling; sign handled in aggregation
        case .alcohol:      return 3   // +3/-0.5 ceiling; sign handled in aggregation
        }
    }

    /// Default-projection mapping from a factor to a coarse `HealthDomain`
    /// for backwards-compatible contributor labelling. Behavior is too broad
    /// for a single mapping — callers should resolve the domain per-signal
    /// for behavior (see `BiologicalAgeEngine.domain(for:)`).
    var defaultDomain: HealthDomain {
        switch self {
        case .fitness:      return .cardio
        case .glycemic:     return .bloodwork
        case .lipids:       return .bloodwork
        case .hemodynamic:  return .bloodPressure
        case .bodyComp:     return .bodyComposition
        case .inflammation: return .bloodwork
        case .organ:        return .bloodwork
        case .behavior:     return .cardio
        case .nicotine:     return .nicotine
        case .alcohol:      return .alcohol
        }
    }
}

// MARK: - Model

struct BioAgeContributor: Identifiable, Hashable {
    let id = UUID()
    let domain: HealthDomain
    let label: String
    let detail: String
    /// Signed years this input adds to (or removes from) the bio-age estimate.
    /// Negative = working in the user's favor.
    let years: Double

    var isFavorable: Bool { years < 0 }
    var magnitude: Double { abs(years) }
}

struct BioAgeEstimate {
    let chronologicalAge: Double
    let biologicalAge: Double
    let delta: Double               // bio - chrono (negative = younger than age)
    let confidence: Double          // 0...1
    let contributors: [BioAgeContributor]
    let trend: TrendDirection
    /// Estimated change in biological years over the prior ~90 days. Negative = getting younger.
    let trendYearsPer90Days: Double?
    let generatedAt: Date

    /// Contributors working in the user's favor (negative years), strongest first.
    var wins: [BioAgeContributor] {
        contributors.filter { $0.years <= -0.25 }.sorted { abs($0.years) > abs($1.years) }
    }
    /// Contributors adding biological years, biggest first — framed as opportunities.
    var opportunities: [BioAgeContributor] {
        contributors.filter { $0.years >= 0.25 }.sorted { $0.years > $1.years }
    }
}

// MARK: - Engine

enum BiologicalAgeEngine {

    /// Coverage target for the confidence calculation: ~10 of the legacy
    /// "primary" signals at full effective weight (VO2, RHR, HRV, HbA1c,
    /// ApoB or LDL, BP, waist or weight, sleep, exercise, one inflammation
    /// marker). Tuned later as new signals come online in Task 4.
    private static let targetCoverage: Double = 10

    static func evaluate(
        manualEntries: [ManualEntry],
        nutritionDigest: NutritionDigest?,
        healthSnapshot: HealthKitSnapshot,
        bloodworkPanels: [BloodworkPanel],
        now: Date = .now
    ) -> BioAgeEstimate? {
        guard let dob = healthSnapshot.dateOfBirth else { return nil }
        let chronoYears = yearsBetween(dob, now)
        guard chronoYears >= 18, chronoYears <= 120 else { return nil }

        let sex = healthSnapshot.biologicalSex
        let latestPanel = bloodworkPanels.sorted { $0.date > $1.date }.first
        let bloodworkFreshness = freshnessForBloodwork(latestPanel: latestPanel, now: now)

        // Build the unsorted reading list. Each per-signal helper returns nil
        // when data is missing or the freshness window is exhausted.
        var readings: [(reading: BioInputReading, label: String, detail: String, domain: HealthDomain)] = []

        // Fitness ----------------------------------------------------------
        if let r = vo2MaxReading(snapshot: healthSnapshot, chronoYears: chronoYears, sex: sex, now: now) {
            readings.append(r)
        }
        if let r = rhrReading(snapshot: healthSnapshot) {
            readings.append(r)
        }
        if let r = hrvReading(snapshot: healthSnapshot, chronoYears: chronoYears, sex: sex) {
            readings.append(r)
        }

        // Glycemic ---------------------------------------------------------
        if let r = hba1cReading(latestPanel: latestPanel, freshness: bloodworkFreshness) {
            readings.append(r)
        }

        // Lipids -----------------------------------------------------------
        if let r = apoBReading(latestPanel: latestPanel, freshness: bloodworkFreshness) {
            readings.append(r)
        } else if let r = ldlReading(latestPanel: latestPanel, freshness: bloodworkFreshness) {
            readings.append(r)
        }

        // Inflammation -----------------------------------------------------
        if let r = hsCrpReading(latestPanel: latestPanel, freshness: bloodworkFreshness) {
            readings.append(r)
        }

        // Hemodynamic ------------------------------------------------------
        if let r = bloodPressureReading(snapshot: healthSnapshot, manualEntries: manualEntries, now: now) {
            readings.append(r)
        }

        // Body composition -------------------------------------------------
        if let r = waistReading(manualEntries: manualEntries, sex: sex, now: now) {
            readings.append(r)
        }
        if let r = weightTrendReading(snapshot: healthSnapshot, now: now) {
            readings.append(r)
        }

        // Behavior ---------------------------------------------------------
        if let r = sleepReading(snapshot: healthSnapshot) {
            readings.append(r)
        }
        if let r = exerciseMinutesReading(snapshot: healthSnapshot) {
            readings.append(r)
        }
        if let r = strengthSessionsReading(snapshot: healthSnapshot) {
            readings.append(r)
        }
        if let r = nutritionReading(digest: nutritionDigest) {
            readings.append(r)
        }

        // Flat-penalty lifestyle signals -----------------------------------
        if let r = nicotineReading(manualEntries: manualEntries, now: now) {
            readings.append(r)
        }
        if let r = alcoholReading(manualEntries: manualEntries, now: now) {
            readings.append(r)
        }

        // Group by factor, compute weighted-mean years per factor, clamp,
        // and sum to a total years delta.
        var totalYears: Double = 0
        let grouped = Dictionary(grouping: readings) { $0.reading.factor }
        for (factor, items) in grouped {
            let live = items.filter { !$0.reading.suppressedByDownstream }
            let totalWeight = live.reduce(0.0) { $0 + $1.reading.effectiveWeight }
            guard totalWeight > 0 else { continue }
            let weightedYears = live.reduce(0.0) {
                $0 + $1.reading.rawYearsImpact * $1.reading.effectiveWeight
            } / max(totalWeight, 1e-9)
            let cap = factor.yearsCap
            totalYears += clamp(weightedYears, -cap, cap)
        }

        let bio = max(0, chronoYears + totalYears)

        // Confidence: how much "coverage" we have versus targetCoverage.
        let totalEffectiveWeight = readings.reduce(0.0) {
            $0 + ($1.reading.suppressedByDownstream ? 0 : $1.reading.effectiveWeight)
        }
        let confidence = clamp(totalEffectiveWeight / targetCoverage, 0, 1)

        // Project to legacy contributor structs for the existing UI. One
        // contributor per reading, signed years preserved.
        let contributors: [BioAgeContributor] = readings.map { item in
            BioAgeContributor(
                domain: item.domain,
                label: item.label,
                detail: item.detail,
                years: item.reading.rawYearsImpact
            )
        }

        // 90-day trend
        let trendYears = compute90DayTrend(
            snapshot: healthSnapshot,
            chronoYears: chronoYears,
            sex: sex,
            now: now
        )
        let trendDir: TrendDirection = {
            guard let t = trendYears else { return .unknown }
            if t <= HealthThresholds.BioAge.trendImprovingThreshold { return .improving }
            if t >= HealthThresholds.BioAge.trendWorseningThreshold { return .worsening }
            return .stable
        }()

        return BioAgeEstimate(
            chronologicalAge: chronoYears,
            biologicalAge: bio,
            delta: bio - chronoYears,
            confidence: confidence,
            contributors: contributors.sorted { abs($0.years) > abs($1.years) },
            trend: trendDir,
            trendYearsPer90Days: trendYears,
            generatedAt: now
        )
    }

    // MARK: - Per-signal builders
    //
    // Each builder returns `nil` when the input is missing OR the freshness
    // window is exhausted. Builders return a `(reading, label, detail, domain)`
    // tuple so the aggregator can both score the reading and project it into
    // a `BioAgeContributor` for the UI.

    private typealias ReadingTuple = (reading: BioInputReading, label: String, detail: String, domain: HealthDomain)

    private static func vo2MaxReading(
        snapshot: HealthKitSnapshot,
        chronoYears: Double,
        sex: HKBiologicalSex,
        now: Date
    ) -> ReadingTuple? {
        guard let sample = snapshot.latestVO2Max else { return nil }
        let value = sample.value
        let mean = vo2Norm(age: chronoYears, sex: sex)
        let sd = HealthThresholds.BioAge.V2.vo2MaxSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .higherIsBetter)
        let yearsPerSD = BioSignal.vo2Max.yearsPerSD ?? 0
        let freshness = freshnessForVO2(sampleDate: sample.date, now: now)
        let quality: Double = (value >= 5 && value <= 90) ? 1 : 0
        let reading = BioInputReading(
            signal: .vo2Max,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: freshness,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "Cardio fitness (VO2 max)", String(format: "%.0f vs ~%.0f norm", value, mean), .cardio)
    }

    private static func rhrReading(snapshot: HealthKitSnapshot) -> ReadingTuple? {
        guard let value = snapshot.restingHeartRateAverage28d else { return nil }
        let mean = HealthThresholds.BioAge.V2.rhrMean
        let sd = HealthThresholds.BioAge.V2.rhrSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .lowerIsBetter)
        let yearsPerSD = BioSignal.rhr.yearsPerSD ?? 0
        let freshness: Double = {
            // If we have <14 days of underlying samples in the recent series, halve it.
            let recent = snapshot.restingHeartRateSeries.count
            if recent > 0 && recent < HealthThresholds.BioAge.V2.rhrMinDays { return 0.5 }
            return 1.0
        }()
        let quality: Double = (value >= 30 && value <= 200) ? 1 : 0
        let reading = BioInputReading(
            signal: .rhr,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: freshness,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "Resting heart rate", "\(Int(value.rounded())) bpm avg", .cardio)
    }

    private static func hrvReading(
        snapshot: HealthKitSnapshot,
        chronoYears: Double,
        sex: HKBiologicalSex
    ) -> ReadingTuple? {
        guard let value = snapshot.hrvAverage28d else { return nil }
        let mean = hrvNorm(age: chronoYears, sex: sex)
        let sd = HealthThresholds.BioAge.V2.hrvSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .higherIsBetter)
        let yearsPerSD = BioSignal.hrv.yearsPerSD ?? 0
        // HRV detail in the legacy view uses ms. There is no underlying sample
        // count exposed, so default freshness = 1.
        let freshness: Double = 1.0
        let quality: Double = (value > 0 && value < 300) ? 1 : 0
        let reading = BioInputReading(
            signal: .hrv,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: freshness,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "Heart rate variability", String(format: "%.0f ms vs ~%.0f norm", value, mean), .cardio)
    }

    private static func hba1cReading(latestPanel: BloodworkPanel?, freshness: Double) -> ReadingTuple? {
        guard freshness > 0, let value = numericMarker(latestPanel, matching: ["hba1c", "a1c"]) else { return nil }
        let mean = HealthThresholds.BioAge.V2.hba1cMean
        let sd = HealthThresholds.BioAge.V2.hba1cSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .lowerIsBetter)
        let yearsPerSD = BioSignal.hba1c.yearsPerSD ?? 0
        let quality: Double = (value >= 3.0 && value <= 20.0) ? 1 : 0
        let reading = BioInputReading(
            signal: .hba1c,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: freshness,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "HbA1c", String(format: "%.1f%%", value), .bloodwork)
    }

    private static func apoBReading(latestPanel: BloodworkPanel?, freshness: Double) -> ReadingTuple? {
        guard freshness > 0, let value = numericMarker(latestPanel, matching: ["apob", "apo b"]) else { return nil }
        let mean = HealthThresholds.BioAge.V2.apoBMean
        let sd = HealthThresholds.BioAge.V2.apoBSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .lowerIsBetter)
        let yearsPerSD = BioSignal.apoB.yearsPerSD ?? 0
        let quality: Double = (value > 10 && value < 400) ? 1 : 0
        let reading = BioInputReading(
            signal: .apoB,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: freshness,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "ApoB", String(format: "%.0f mg/dL", value), .bloodwork)
    }

    private static func ldlReading(latestPanel: BloodworkPanel?, freshness: Double) -> ReadingTuple? {
        guard freshness > 0, let value = numericMarker(latestPanel, matching: ["ldl-c", "ldl"]) else { return nil }
        let mean = HealthThresholds.BioAge.V2.ldlMean
        let sd = HealthThresholds.BioAge.V2.ldlSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .lowerIsBetter)
        let yearsPerSD = BioSignal.ldl.yearsPerSD ?? 0
        let quality: Double = (value > 10 && value < 500) ? 1 : 0
        let reading = BioInputReading(
            signal: .ldl,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: freshness,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "LDL-C", String(format: "%.0f mg/dL", value), .bloodwork)
    }

    private static func hsCrpReading(latestPanel: BloodworkPanel?, freshness: Double) -> ReadingTuple? {
        guard freshness > 0, let raw = numericMarker(latestPanel, matching: ["hs-crp", "hs crp", "crp"]) else { return nil }
        // hs-CRP distributes log-normally; reference mean/SD live in log10 space.
        guard raw > 0 else { return nil }
        let logged = log10(raw)
        let mean = HealthThresholds.BioAge.V2.hsCrpLog10Mean
        let sd = HealthThresholds.BioAge.V2.hsCrpLog10SD
        let z = BioInputReading.zScore(value: logged, mean: mean, sd: sd, direction: .lowerIsBetter)
        let yearsPerSD = BioSignal.hsCrp.yearsPerSD ?? 0
        let quality: Double = (raw > 0 && raw < 100) ? 1 : 0
        let reading = BioInputReading(
            signal: .hsCrp,
            value: logged,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: freshness,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "Inflammation (hs-CRP)", String(format: "%.1f mg/L", raw), .bloodwork)
    }

    private static func bloodPressureReading(
        snapshot: HealthKitSnapshot,
        manualEntries: [ManualEntry],
        now: Date
    ) -> ReadingTuple? {
        guard let bp = recentBpAverage(snapshot: snapshot, manualEntries: manualEntries, now: now) else { return nil }
        // Score systolic and diastolic z separately, then average to a single
        // "BP composite z" — keeps the signal as a single reading inside the
        // hemodynamic factor.
        let sysZ = BioInputReading.zScore(
            value: bp.systolic,
            mean: HealthThresholds.BioAge.V2.systolicBPMean,
            sd: HealthThresholds.BioAge.V2.systolicBPSD,
            direction: .lowerIsBetter
        )
        let diaZ = BioInputReading.zScore(
            value: bp.diastolic,
            mean: HealthThresholds.BioAge.V2.diastolicBPMean,
            sd: HealthThresholds.BioAge.V2.diastolicBPSD,
            direction: .lowerIsBetter
        )
        let z = (sysZ + diaZ) / 2
        let yearsPerSD = BioSignal.bloodPressure.yearsPerSD ?? 0
        // Implausible BP ranges fall back to 0 quality so they don't poison.
        let quality: Double = (bp.systolic >= 60 && bp.systolic <= 260 && bp.diastolic >= 30 && bp.diastolic <= 200) ? 1 : 0
        let reading = BioInputReading(
            signal: .bloodPressure,
            value: bp.systolic,
            referenceMean: HealthThresholds.BioAge.V2.systolicBPMean,
            referenceSD: HealthThresholds.BioAge.V2.systolicBPSD,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: 1.0,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "Blood pressure", "\(Int(bp.systolic.rounded()))/\(Int(bp.diastolic.rounded())) avg", .bloodPressure)
    }

    private static func waistReading(
        manualEntries: [ManualEntry],
        sex: HKBiologicalSex,
        now: Date
    ) -> ReadingTuple? {
        guard let latest = manualEntries
            .filter({ $0.entryType == .waist })
            .max(by: { $0.date < $1.date }),
              let value = latest.primaryValue else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -HealthThresholds.BodyComp.lookbackDays, to: now) ?? now
        guard latest.date >= cutoff else { return nil }
        let mean: Double = (sex == .female) ? HealthThresholds.BioAge.V2.waistFemaleMean : HealthThresholds.BioAge.V2.waistMaleMean
        let sd: Double   = (sex == .female) ? HealthThresholds.BioAge.V2.waistFemaleSD   : HealthThresholds.BioAge.V2.waistMaleSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .lowerIsBetter)
        let yearsPerSD = BioSignal.waist.yearsPerSD ?? 0
        let quality: Double = (value > 40 && value < 200) ? 1 : 0
        let reading = BioInputReading(
            signal: .waist,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: 1.0,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "Waist circumference", String(format: "%.0f cm", value), .bodyComposition)
    }

    private static func weightTrendReading(snapshot: HealthKitSnapshot, now: Date) -> ReadingTuple? {
        let series = snapshot.bodyMassSeries.sorted { $0.date < $1.date }
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        let windowSamples = series.filter { $0.date >= cutoff }
        guard windowSamples.count >= HealthThresholds.BioAge.V2.weightSeriesMinPoints,
              let latest = series.last,
              let baseline = (series.first(where: { $0.date <= cutoff })?.value) ?? series.first?.value,
              baseline > 0 else { return nil }
        // weightTrend signal is signed % change over 90d. Positive = gaining weight.
        let pct = (latest.value - baseline) / baseline * 100
        let mean = HealthThresholds.BioAge.V2.weightTrendMean
        let sd = HealthThresholds.BioAge.V2.weightTrendSD
        let z = BioInputReading.zScore(value: pct, mean: mean, sd: sd, direction: .lowerIsBetter)
        let yearsPerSD = BioSignal.weightTrend.yearsPerSD ?? 0
        let reading = BioInputReading(
            signal: .weightTrend,
            value: pct,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: 1.0,
            qualityWeight: 1.0,
            suppressedByDownstream: false
        )
        return (reading, "Body weight trend", String(format: "Δ %+.1f kg vs 90d ago", latest.value - baseline), .bodyComposition)
    }

    private static func sleepReading(snapshot: HealthKitSnapshot) -> ReadingTuple? {
        guard let value = snapshot.sleepHoursAverage7d else { return nil }
        let mean = HealthThresholds.BioAge.V2.sleepMean
        let sd = HealthThresholds.BioAge.V2.sleepSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .higherIsBetter)
        let yearsPerSD = BioSignal.sleep.yearsPerSD ?? 0
        let quality: Double = (value > 0 && value < 24) ? 1 : 0
        let reading = BioInputReading(
            signal: .sleep,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: 1.0,
            qualityWeight: quality,
            suppressedByDownstream: false
        )
        return (reading, "Sleep", String(format: "%.1f h/night avg", value), .sleep)
    }

    private static func exerciseMinutesReading(snapshot: HealthKitSnapshot) -> ReadingTuple? {
        guard let value = snapshot.exerciseMinutesPerWeek else { return nil }
        let mean = HealthThresholds.BioAge.V2.exerciseMinutesMean
        let sd = HealthThresholds.BioAge.V2.exerciseMinutesSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .higherIsBetter)
        let yearsPerSD = BioSignal.exerciseMinutes.yearsPerSD ?? 0
        let reading = BioInputReading(
            signal: .exerciseMinutes,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: 1.0,
            qualityWeight: 1.0,
            suppressedByDownstream: false
        )
        return (reading, "Weekly exercise", "\(Int(value.rounded())) min/wk", .cardio)
    }

    private static func strengthSessionsReading(snapshot: HealthKitSnapshot) -> ReadingTuple? {
        guard let sessions = snapshot.strengthWorkoutsLast7Days else { return nil }
        let value = Double(sessions)
        let mean = HealthThresholds.BioAge.V2.strengthSessionsMean
        let sd = HealthThresholds.BioAge.V2.strengthSessionsSD
        let z = BioInputReading.zScore(value: value, mean: mean, sd: sd, direction: .higherIsBetter)
        let yearsPerSD = BioSignal.strengthSessions.yearsPerSD ?? 0
        let reading = BioInputReading(
            signal: .strengthSessions,
            value: value,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: 1.0,
            qualityWeight: 1.0,
            suppressedByDownstream: false
        )
        return (reading, "Strength training", "\(sessions) session\(sessions == 1 ? "" : "s") this week", .strength)
    }

    private static func nutritionReading(digest: NutritionDigest?) -> ReadingTuple? {
        guard let digest = digest else { return nil }
        // Convert the rollup-based nutrition signal into a z-score in
        // "favorable-buckets" space — favorable = good - bad. Mean = 0,
        // SD = 1 keeps things stable until we have a real nutrition score.
        let favorable: [NutrientBucket] = [.plantVariety, .leafyGreenDays, .legumeDays, .fermentedDays]
        let unfavorable: [NutrientBucket] = [.ultraProcessedMeals, .processedMeatMeals, .friedMeals]
        var good = 0
        var bad = 0
        for b in favorable {
            if let r = digest.rollup(for: b), (r.status == .ok || r.status == .high || r.status == .veryHigh) {
                good += 1
            }
        }
        for b in unfavorable {
            if let r = digest.rollup(for: b), (r.status == .high || r.status == .veryHigh) {
                bad += 1
            }
        }
        // Nothing scored at all — don't contribute.
        guard (good + bad) > 0 else { return nil }
        let score = Double(good - bad)
        let mean = 0.0
        let sd = 1.0
        let z = BioInputReading.zScore(value: score, mean: mean, sd: sd, direction: .higherIsBetter)
        let yearsPerSD = BioSignal.nutrition.yearsPerSD ?? 0
        let detail: String
        if good >= 2 && bad == 0 { detail = "Plants + variety on track" }
        else if bad >= 2 { detail = "Frequent ultra-processed meals" }
        else { detail = "Mixed signal" }
        let reading = BioInputReading(
            signal: .nutrition,
            value: score,
            referenceMean: mean,
            referenceSD: sd,
            zScore: z,
            rawYearsImpact: -z * yearsPerSD,
            freshnessWeight: 1.0,
            qualityWeight: 1.0,
            suppressedByDownstream: false
        )
        return (reading, "Diet quality", detail, .fiber)
    }

    private static func nicotineReading(manualEntries: [ManualEntry], now: Date) -> ReadingTuple? {
        let since = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        let recent = manualEntries.filter { $0.entryType == .nicotine && $0.date >= since }
        guard !recent.isEmpty else { return nil }
        let usedRecently = recent.contains { $0.booleanValue == true }
        let years: Double = usedRecently
            ? HealthThresholds.BioAge.V2.nicotineActiveYears
            : HealthThresholds.BioAge.V2.nicotineCleanYears
        let label = usedRecently ? "Nicotine use" : "No nicotine"
        let detail = usedRecently ? "Logged in last 60d" : "Clean log for 60d+"
        let reading = BioInputReading(
            signal: .nicotine,
            value: usedRecently ? 1 : 0,
            referenceMean: 0,
            referenceSD: 0,
            zScore: 0,
            rawYearsImpact: years,
            freshnessWeight: 1.0,
            qualityWeight: 1.0,
            suppressedByDownstream: false
        )
        return (reading, label, detail, .nicotine)
    }

    private static func alcoholReading(manualEntries: [ManualEntry], now: Date) -> ReadingTuple? {
        let since = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        let recent = manualEntries.filter { $0.entryType == .alcohol && $0.date >= since }
        guard !recent.isEmpty else { return nil }
        let heavy = recent.filter { $0.alcoholLevel == .heavy }.count
        let light = recent.filter { $0.alcoholLevel == .light }.count
        let none  = recent.filter { $0.alcoholLevel == AlcoholLevel.none }.count

        let years: Double
        let label: String
        let detail: String
        if heavy >= 2 {
            years = HealthThresholds.BioAge.V2.alcoholHeavyYears
            label = "Heavy drinking"
            detail = "\(heavy) heavy days/14d"
        } else if (heavy + light) >= 5 {
            years = HealthThresholds.BioAge.V2.alcoholFrequentYears
            label = "Frequent drinking"
            detail = "\(heavy + light) drinking days/14d"
        } else if none >= 7 && (heavy + light) == 0 {
            years = HealthThresholds.BioAge.V2.alcoholNoneYears
            label = "Alcohol-free"
            detail = "No drinks logged 14d"
        } else {
            return nil
        }
        let reading = BioInputReading(
            signal: .alcohol,
            value: Double(heavy + light),
            referenceMean: 0,
            referenceSD: 0,
            zScore: 0,
            rawYearsImpact: years,
            freshnessWeight: 1.0,
            qualityWeight: 1.0,
            suppressedByDownstream: false
        )
        return (reading, label, detail, .alcohol)
    }

    // MARK: - Norm helpers

    private static func vo2Norm(age: Double, sex: HKBiologicalSex) -> Double {
        switch sex {
        case .female: return interpolateDecadeNorm(age: age, table: HealthThresholds.BioAge.V2.vo2NormsFemale)
        case .male:   return interpolateDecadeNorm(age: age, table: HealthThresholds.BioAge.V2.vo2NormsMale)
        default:
            let m = interpolateDecadeNorm(age: age, table: HealthThresholds.BioAge.V2.vo2NormsMale)
            let f = interpolateDecadeNorm(age: age, table: HealthThresholds.BioAge.V2.vo2NormsFemale)
            return (m + f) / 2.0
        }
    }

    private static func hrvNorm(age: Double, sex: HKBiologicalSex) -> Double {
        switch sex {
        case .female: return interpolateDecadeNorm(age: age, table: HealthThresholds.BioAge.V2.hrvNormsFemale)
        case .male:   return interpolateDecadeNorm(age: age, table: HealthThresholds.BioAge.V2.hrvNormsMale)
        default:
            let m = interpolateDecadeNorm(age: age, table: HealthThresholds.BioAge.V2.hrvNormsMale)
            let f = interpolateDecadeNorm(age: age, table: HealthThresholds.BioAge.V2.hrvNormsFemale)
            return (m + f) / 2.0
        }
    }

    // MARK: - Freshness helpers

    private static func freshnessForVO2(sampleDate: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(sampleDate) / 86_400)
        let fresh = Double(HealthThresholds.BioAge.V2.vo2FreshDays)
        let decay = Double(HealthThresholds.BioAge.V2.vo2DecayDays)
        if days <= fresh { return 1.0 }
        if days >= decay { return 0.0 }
        return 1.0 - (days - fresh) / (decay - fresh)
    }

    private static func freshnessForBloodwork(latestPanel: BloodworkPanel?, now: Date) -> Double {
        guard let panel = latestPanel else { return 0 }
        let months = now.timeIntervalSince(panel.date) / (86_400 * 30)
        if months <= Double(HealthThresholds.BioAge.V2.bloodworkFullMonths)    { return 1.0 }
        if months <= Double(HealthThresholds.BioAge.V2.bloodworkHalfMonths)    { return 0.5 }
        if months <= Double(HealthThresholds.BioAge.V2.bloodworkQuarterMonths) { return 0.25 }
        return 0
    }

    // MARK: - Trend

    private static func compute90DayTrend(
        snapshot: HealthKitSnapshot,
        chronoYears: Double,
        sex: HKBiologicalSex,
        now: Date
    ) -> Double? {
        var deltas: [Double] = []

        // VO2 max: now vs ~90d-ago using continuous z-score-driven years.
        if let vo2Now = snapshot.latestVO2Max?.value, !snapshot.vo2MaxSeries.isEmpty {
            let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
            let older = snapshot.vo2MaxSeries.filter { $0.date <= cutoff }
            if let vo2Then = older.last?.value {
                let mean = vo2Norm(age: chronoYears, sex: sex)
                let sd = HealthThresholds.BioAge.V2.vo2MaxSD
                let yps = BioSignal.vo2Max.yearsPerSD ?? 0
                let zNow  = BioInputReading.zScore(value: vo2Now,  mean: mean, sd: sd, direction: .higherIsBetter)
                let zThen = BioInputReading.zScore(value: vo2Then, mean: mean, sd: sd, direction: .higherIsBetter)
                deltas.append((-zNow * yps) - (-zThen * yps))
            }
        }

        // RHR: 28d "now" vs 90d "then".
        if let r28 = snapshot.restingHeartRateAverage28d, let r90 = snapshot.restingHeartRateAverage90d {
            let mean = HealthThresholds.BioAge.V2.rhrMean
            let sd = HealthThresholds.BioAge.V2.rhrSD
            let yps = BioSignal.rhr.yearsPerSD ?? 0
            let zNow  = BioInputReading.zScore(value: r28, mean: mean, sd: sd, direction: .lowerIsBetter)
            let zThen = BioInputReading.zScore(value: r90, mean: mean, sd: sd, direction: .lowerIsBetter)
            deltas.append((-zNow * yps) - (-zThen * yps))
        }

        // Body mass drift: % change over 90 days, scored via weightTrend z.
        let series = snapshot.bodyMassSeries.sorted { $0.date < $1.date }
        if let latest = series.last {
            let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
            if let then = series.first(where: { $0.date <= cutoff })?.value, then > 0 {
                let pct = (latest.value - then) / then * 100
                if abs(pct) >= HealthThresholds.BodyComp.weightChangePercentBorderline * 100 {
                    let mean = HealthThresholds.BioAge.V2.weightTrendMean
                    let sd = HealthThresholds.BioAge.V2.weightTrendSD
                    let yps = BioSignal.weightTrend.yearsPerSD ?? 0
                    let z = BioInputReading.zScore(value: pct, mean: mean, sd: sd, direction: .lowerIsBetter)
                    // "Then" baseline is the zero-drift case, so delta is just the
                    // years impact attributable to the observed drift.
                    deltas.append(-z * yps)
                }
            }
        }

        guard !deltas.isEmpty else { return nil }
        return deltas.reduce(0, +)
    }

    // MARK: - Marker / entry helpers

    private static func numericMarker(_ panel: BloodworkPanel?, matching needles: [String]) -> Double? {
        guard let markers = panel?.markers else { return nil }
        let lowered = needles.map { $0.lowercased() }
        for m in markers {
            let name = m.name.lowercased()
            if lowered.contains(where: { name.contains($0) }) {
                return parseLeadingDouble(m.value)
            }
        }
        return nil
    }

    private static func parseLeadingDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        // Strip leading non-numeric chars (e.g. "<", ">", "~").
        let scanned = trimmed.drop(while: { !$0.isNumber && $0 != "-" && $0 != "." })
        var numeric = ""
        var sawDot = false
        for ch in scanned {
            if ch.isNumber { numeric.append(ch) }
            else if ch == "." && !sawDot { numeric.append(ch); sawDot = true }
            else if ch == "-" && numeric.isEmpty { numeric.append(ch) }
            else { break }
        }
        return Double(numeric)
    }

    private static func recentBpAverage(
        snapshot: HealthKitSnapshot,
        manualEntries: [ManualEntry],
        now: Date
    ) -> (systolic: Double, diastolic: Double)? {
        var readings = snapshot.bloodPressureReadings
        for e in manualEntries where e.entryType == .bloodPressure {
            if let s = e.primaryValue, let d = e.secondaryValue {
                readings.append(BloodPressureReading(systolic: s, diastolic: d, date: e.date))
            }
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -HealthThresholds.BP.recentWindowDays, to: now) ?? now
        let recent = readings.filter { $0.date >= cutoff }
        guard !recent.isEmpty,
              let s = TrendAnalyzer.mean(recent.map(\.systolic)),
              let d = TrendAnalyzer.mean(recent.map(\.diastolic)) else { return nil }
        return (s, d)
    }

    // MARK: - General helpers

    private static func yearsBetween(_ start: Date, _ end: Date) -> Double {
        let comps = Calendar.current.dateComponents([.day], from: start, to: end)
        return Double(comps.day ?? 0) / 365.25
    }

    // Local clamp to avoid name collision with stdlib variants pulled from other modules.
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
