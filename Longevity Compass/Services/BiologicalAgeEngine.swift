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

/// Direction-agnostic z-score. Returns a SIGNED z where `+` always means
/// "better than typical".
///
/// - For `.higherIsBetter`: `(value - mean) / sd`
/// - For `.lowerIsBetter`:  `(mean - value) / sd`
/// - If `sd == 0`, returns 0 as a safeguard.
func bioZScore(value: Double, mean: Double, sd: Double, direction: BioDirection) -> Double {
    guard sd > 0 else { return 0 }
    switch direction {
    case .higherIsBetter: return (value - mean) / sd
    case .lowerIsBetter:  return (mean - value) / sd
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
    return table[last] ?? 0
}

extension BioSignal {
    /// How many biological-age years one standard deviation of this signal
    /// is worth in the aggregator. Used as the multiplier on the (capped)
    /// z-score in Layer A.
    ///
    /// Nicotine and alcohol return 0 — they're handled as flat lifestyle
    /// penalties (see `HealthThresholds.BioAge.V2.nicotineActiveYears` etc.)
    /// rather than via z-score scaling.
    var yearsPerSD: Double {
        switch self {
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
        case .nicotine:         return 0.0   // flat; handled separately
        case .alcohol:          return 0.0   // flat; handled separately
        case .nutrition:        return 0.5
        }
    }
}

extension BioFactor {
    /// Maximum absolute years-impact a single factor's combined signals may
    /// contribute. For nicotine/alcohol the cap also represents the magnitude
    /// ceiling of the flat penalty (sign handled by the aggregator).
    var cap: Double {
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
        var contributors: [BioAgeContributor] = []
        var primaryPresent = 0

        // VO2 max (cardio fitness)
        if let vo2 = healthSnapshot.latestVO2Max?.value {
            let norm = vo2Norm(age: chronoYears, sex: sex)
            let yrs = clamp(
                (norm - vo2) * HealthThresholds.BioAge.vo2YearsPerUnitDelta,
                -HealthThresholds.BioAge.vo2MaxDelta,
                HealthThresholds.BioAge.vo2MaxDelta
            )
            contributors.append(BioAgeContributor(
                domain: .cardio,
                label: "Cardio fitness (VO2 max)",
                detail: String(format: "%.0f vs ~%.0f norm", vo2, norm),
                years: yrs
            ))
            primaryPresent += 1
        }

        // Resting heart rate
        if let rhr = healthSnapshot.restingHeartRateAverage28d {
            let yrs = lookupBand(rhr, map: HealthThresholds.BioAge.rhrYearsMap)
            contributors.append(BioAgeContributor(
                domain: .cardio,
                label: "Resting heart rate",
                detail: "\(Int(rhr.rounded())) bpm avg",
                years: yrs
            ))
            primaryPresent += 1
        }

        // Blood pressure
        if let bp = recentBpAverage(snapshot: healthSnapshot, manualEntries: manualEntries, now: now) {
            let yrs = bpYears(systolic: bp.systolic, diastolic: bp.diastolic)
            contributors.append(BioAgeContributor(
                domain: .bloodPressure,
                label: "Blood pressure",
                detail: "\(Int(bp.systolic.rounded()))/\(Int(bp.diastolic.rounded())) avg",
                years: yrs
            ))
            primaryPresent += 1
        }

        // Bloodwork: latest panel only
        let latestPanel = bloodworkPanels.sorted { $0.date > $1.date }.first

        if let hba1c = numericMarker(latestPanel, matching: ["hba1c", "a1c"]) {
            let yrs = lookupBand(hba1c, map: HealthThresholds.BioAge.hba1cYearsMap)
            contributors.append(BioAgeContributor(
                domain: .bloodwork,
                label: "HbA1c",
                detail: String(format: "%.1f%%", hba1c),
                years: yrs
            ))
            primaryPresent += 1
        }

        if let crp = numericMarker(latestPanel, matching: ["hs-crp", "hs crp", "crp"]) {
            let yrs = lookupBand(crp, map: HealthThresholds.BioAge.crpYearsMap)
            contributors.append(BioAgeContributor(
                domain: .bloodwork,
                label: "Inflammation (hs-CRP)",
                detail: String(format: "%.1f mg/L", crp),
                years: yrs
            ))
            primaryPresent += 1
        }

        if let apob = numericMarker(latestPanel, matching: ["apob", "apo b"]) {
            let yrs = lookupBand(apob, map: HealthThresholds.BioAge.apoBYearsMap)
            contributors.append(BioAgeContributor(
                domain: .bloodwork,
                label: "ApoB",
                detail: String(format: "%.0f mg/dL", apob),
                years: yrs
            ))
            primaryPresent += 1
        } else if let ldl = numericMarker(latestPanel, matching: ["ldl-c", "ldl"]) {
            let yrs = lookupBand(ldl, map: HealthThresholds.BioAge.ldlYearsMap)
            contributors.append(BioAgeContributor(
                domain: .bloodwork,
                label: "LDL-C",
                detail: String(format: "%.0f mg/dL", ldl),
                years: yrs
            ))
            primaryPresent += 1
        }

        // Waist circumference (manual). Falls back to weight stability via HK series.
        if let waist = mostRecentValue(manualEntries, type: .waist) {
            let yrs = waistYears(waist, sex: sex)
            contributors.append(BioAgeContributor(
                domain: .bodyComposition,
                label: "Waist circumference",
                detail: String(format: "%.0f cm", waist),
                years: yrs
            ))
            primaryPresent += 1
        } else if let wt = weightDriftContributor(snapshot: healthSnapshot, now: now) {
            contributors.append(wt)
            primaryPresent += 1
        }

        // Sleep
        if let sleep = healthSnapshot.sleepHoursAverage7d {
            let yrs = sleepYears(sleep)
            contributors.append(BioAgeContributor(
                domain: .sleep,
                label: "Sleep",
                detail: String(format: "%.1f h/night avg", sleep),
                years: yrs
            ))
            primaryPresent += 1
        }

        // Exercise minutes (Apple Exercise Time)
        if let mins = healthSnapshot.exerciseMinutesPerWeek {
            let yrs = exerciseYears(mins)
            contributors.append(BioAgeContributor(
                domain: .cardio,
                label: "Weekly exercise",
                detail: "\(Int(mins.rounded())) min/wk",
                years: yrs
            ))
            primaryPresent += 1
        }

        // Strength sessions
        if let sess = healthSnapshot.strengthWorkoutsLast7Days, sess > 0 || (healthSnapshot.workoutsLast28Days ?? 0) > 0 {
            let yrs: Double
            if sess >= HealthThresholds.BioAge.strengthGoodSessions {
                yrs = HealthThresholds.BioAge.strengthYearsGood
            } else if sess == 0 {
                yrs = HealthThresholds.BioAge.strengthYearsNone
            } else {
                yrs = 0
            }
            if abs(yrs) > 0.01 {
                contributors.append(BioAgeContributor(
                    domain: .strength,
                    label: "Strength training",
                    detail: "\(sess) session\(sess == 1 ? "" : "s") this week",
                    years: yrs
                ))
            }
        }

        // Nicotine (high impact)
        if let nic = nicotineContributor(manualEntries, now: now) {
            contributors.append(nic)
        }

        // Alcohol
        if let alc = alcoholContributor(manualEntries, now: now) {
            contributors.append(alc)
        }

        // Nutrition — small signal, only when digest is meaningful.
        if let digest = nutritionDigest, let nut = nutritionContributor(digest) {
            contributors.append(nut)
        }

        // Aggregate
        let totalYears = contributors.reduce(0.0) { $0 + $1.years }
        let bio = max(0, chronoYears + totalYears)
        let confidence = min(1.0, Double(primaryPresent) / Double(HealthThresholds.BioAge.primaryInputCount))

        // 90-day trend (driven by VO2 max + RHR + body mass — the inputs we have history for)
        let trendYears = compute90DayTrend(snapshot: healthSnapshot, chronoYears: chronoYears, sex: sex, now: now)
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

    // MARK: - Per-input helpers

    private static func vo2Norm(age: Double, sex: HKBiologicalSex) -> Double {
        let table: [Int: Double] = {
            switch sex {
            case .female: return HealthThresholds.BioAge.vo2NormsFemale
            case .male:   return HealthThresholds.BioAge.vo2NormsMale
            default:
                // Mix M/F when sex is unknown.
                let m = HealthThresholds.BioAge.vo2NormsMale
                let f = HealthThresholds.BioAge.vo2NormsFemale
                return m.reduce(into: [Int: Double]()) { acc, kv in
                    acc[kv.key] = (kv.value + (f[kv.key] ?? kv.value)) / 2.0
                }
            }
        }()
        let decade = min(max(20, Int(age / 10) * 10), 70)
        return table[decade] ?? table[40] ?? 35
    }

    private static func bpYears(systolic: Double, diastolic: Double) -> Double {
        if systolic >= HealthThresholds.BP.urgentSystolicMin || diastolic >= HealthThresholds.BP.urgentDiastolicMin {
            return HealthThresholds.BioAge.bpUrgentYears
        }
        if systolic >= 140 || diastolic >= 90 { return HealthThresholds.BioAge.bpStage2Years }
        if systolic >= HealthThresholds.BP.badSystolicMin || diastolic >= HealthThresholds.BP.badDiastolicMin {
            return HealthThresholds.BioAge.bpStage1Years
        }
        if systolic >= HealthThresholds.BP.borderlineSystolicMin { return HealthThresholds.BioAge.bpElevatedYears }
        return HealthThresholds.BioAge.bpOptimalYears
    }

    private static func waistYears(_ cm: Double, sex: HKBiologicalSex) -> Double {
        let low: Double
        let high: Double
        switch sex {
        case .female:
            low = HealthThresholds.BioAge.waistFemaleLow
            high = HealthThresholds.BioAge.waistFemaleHigh
        default:
            low = HealthThresholds.BioAge.waistMaleLow
            high = HealthThresholds.BioAge.waistMaleHigh
        }
        if cm >= high { return 2 }
        if cm >= low  { return 1 }
        return -1
    }

    private static func sleepYears(_ hours: Double) -> Double {
        if hours < 6 { return HealthThresholds.BioAge.sleepBadYears }
        if hours < 7 { return HealthThresholds.BioAge.sleepBorderlineYears }
        if hours <= 9 { return HealthThresholds.BioAge.sleepGoodYears }
        return HealthThresholds.BioAge.sleepBorderlineYears
    }

    private static func exerciseYears(_ minutes: Double) -> Double {
        if minutes >= HealthThresholds.BioAge.exerciseGoodMinutes     { return HealthThresholds.BioAge.exerciseGoodYears }
        if minutes >= HealthThresholds.BioAge.exerciseAdequateMinutes { return HealthThresholds.BioAge.exerciseAdequateYears }
        if minutes >= HealthThresholds.BioAge.exerciseLowMinutes      { return 0 }
        if minutes <= 30                                              { return HealthThresholds.BioAge.exerciseSedentaryYears }
        return HealthThresholds.BioAge.exerciseLowYears
    }

    private static func nicotineContributor(_ entries: [ManualEntry], now: Date) -> BioAgeContributor? {
        let since = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        let recent = entries.filter { $0.entryType == .nicotine && $0.date >= since }
        guard !recent.isEmpty else { return nil }
        let usedRecently = recent.contains { $0.booleanValue == true }
        if usedRecently {
            return BioAgeContributor(
                domain: .nicotine,
                label: "Nicotine use",
                detail: "Logged in last 60d",
                years: HealthThresholds.BioAge.nicotineActiveYears
            )
        }
        return BioAgeContributor(
            domain: .nicotine,
            label: "No nicotine",
            detail: "Clean log for 60d+",
            years: -1
        )
    }

    private static func alcoholContributor(_ entries: [ManualEntry], now: Date) -> BioAgeContributor? {
        let since = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        let recent = entries.filter { $0.entryType == .alcohol && $0.date >= since }
        guard !recent.isEmpty else { return nil }
        let heavy = recent.filter { $0.alcoholLevel == .heavy }.count
        let light = recent.filter { $0.alcoholLevel == .light }.count
        let none  = recent.filter { $0.alcoholLevel == AlcoholLevel.none }.count

        if heavy >= 2 {
            return BioAgeContributor(
                domain: .alcohol,
                label: "Heavy drinking",
                detail: "\(heavy) heavy days/14d",
                years: HealthThresholds.BioAge.alcoholHeavyYears
            )
        }
        if (heavy + light) >= 5 {
            return BioAgeContributor(
                domain: .alcohol,
                label: "Frequent drinking",
                detail: "\(heavy + light) drinking days/14d",
                years: HealthThresholds.BioAge.alcoholFrequentYears
            )
        }
        if none >= 7 && (heavy + light) == 0 {
            return BioAgeContributor(
                domain: .alcohol,
                label: "Alcohol-free",
                detail: "No drinks logged 14d",
                years: HealthThresholds.BioAge.alcoholNoneYears
            )
        }
        return nil
    }

    private static func nutritionContributor(_ digest: NutritionDigest) -> BioAgeContributor? {
        // Lightweight: count favorable vs unfavorable rollups.
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
        if good >= 2 && bad == 0 {
            return BioAgeContributor(
                domain: .fiber,
                label: "Diet quality",
                detail: "Plants + variety on track",
                years: HealthThresholds.BioAge.nutritionGoodYears
            )
        }
        if bad >= 2 {
            return BioAgeContributor(
                domain: .fiber,
                label: "Diet quality",
                detail: "Frequent ultra-processed meals",
                years: HealthThresholds.BioAge.nutritionPoorYears
            )
        }
        return nil
    }

    private static func weightDriftContributor(snapshot: HealthKitSnapshot, now: Date) -> BioAgeContributor? {
        let series = snapshot.bodyMassSeries.sorted { $0.date < $1.date }
        guard let latest = series.last else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -HealthThresholds.BodyComp.lookbackDays, to: now) ?? now
        guard let baseline = series.first(where: { $0.date <= cutoff })?.value ?? series.first?.value,
              baseline > 0, series.count >= 2 else { return nil }
        let pct = (latest.value - baseline) / baseline
        // Only contributes if meaningfully drifting.
        guard abs(pct) >= HealthThresholds.BodyComp.weightChangePercentBorderline else { return nil }
        let yrs: Double = pct > 0 ? (pct >= HealthThresholds.BodyComp.weightChangePercentBad ? 2 : 1) : -0.5
        return BioAgeContributor(
            domain: .bodyComposition,
            label: "Body weight trend",
            detail: String(format: "Δ %+.1f kg vs 90d ago", latest.value - baseline),
            years: yrs
        )
    }

    // MARK: - Trend

    private static func compute90DayTrend(
        snapshot: HealthKitSnapshot,
        chronoYears: Double,
        sex: HKBiologicalSex,
        now: Date
    ) -> Double? {
        var deltas: [Double] = []

        // VO2 max: compare current value vs ~90d-ago sample.
        if let vo2Now = snapshot.latestVO2Max?.value, !snapshot.vo2MaxSeries.isEmpty {
            let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
            let oldSeries = snapshot.vo2MaxSeries.filter { $0.date <= cutoff }
            if let vo2Then = oldSeries.last?.value {
                let norm = vo2Norm(age: chronoYears, sex: sex)
                let yrsNow  = clamp((norm - vo2Now)  * HealthThresholds.BioAge.vo2YearsPerUnitDelta,
                                    -HealthThresholds.BioAge.vo2MaxDelta, HealthThresholds.BioAge.vo2MaxDelta)
                let yrsThen = clamp((norm - vo2Then) * HealthThresholds.BioAge.vo2YearsPerUnitDelta,
                                    -HealthThresholds.BioAge.vo2MaxDelta, HealthThresholds.BioAge.vo2MaxDelta)
                deltas.append(yrsNow - yrsThen)
            }
        }

        // RHR: 28d avg vs 90d avg (28d represents "now", 90d represents the longer-window baseline).
        if let r28 = snapshot.restingHeartRateAverage28d, let r90 = snapshot.restingHeartRateAverage90d {
            let yrsNow  = lookupBand(r28, map: HealthThresholds.BioAge.rhrYearsMap)
            let yrsThen = lookupBand(r90, map: HealthThresholds.BioAge.rhrYearsMap)
            deltas.append(yrsNow - yrsThen)
        }

        // Body mass: latest vs ~90d ago.
        let series = snapshot.bodyMassSeries.sorted { $0.date < $1.date }
        if let latest = series.last {
            let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
            if let then = series.first(where: { $0.date <= cutoff })?.value, then > 0 {
                let pct = (latest.value - then) / then
                if abs(pct) >= HealthThresholds.BodyComp.weightChangePercentBorderline {
                    // Same sign convention as weight-drift contributor.
                    let delta = pct > 0 ? (pct >= HealthThresholds.BodyComp.weightChangePercentBad ? 2.0 : 1.0) : -0.5
                    deltas.append(delta)
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

    private static func mostRecentValue(_ entries: [ManualEntry], type: ManualEntryType) -> Double? {
        entries
            .filter { $0.entryType == type }
            .max(by: { $0.date < $1.date })?
            .primaryValue
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

    private static func lookupBand(_ value: Double, map: [(maxValue: Double, years: Double)]) -> Double {
        for entry in map {
            if value < entry.maxValue { return entry.years }
        }
        return map.last?.years ?? 0
    }

    // Local clamp to avoid name collision with stdlib variants pulled from other modules.
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

