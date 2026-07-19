import Foundation

// All tunable constants for the priority engine live here.
// Edit values, not call sites — the engine reads from this file only.

enum HealthThresholds {

    // MARK: - Impact weights (per domain, used as base priorityScore)

    static let impactWeights: [HealthDomain: Double] = [
        .bloodPressure:   100,
        .nicotine:        100,
        .cardio:           90,
        .strength:         80,
        .bodyComposition:  75,
        .sleep:            75,
        .alcohol:          65,
        .protein:          55,
        .fiber:            55,
        .omega3:           40,
        .dental:           25,
        .bloodwork:        85,
    ]

    static func impactWeight(_ domain: HealthDomain) -> Double {
        impactWeights[domain] ?? 50
    }

    // MARK: - Scoring contributions

    enum Score {
        static let riskGood            = 0.0
        static let riskBorderline      = 20.0
        static let riskBad             = 40.0
        static let riskUrgent          = 70.0
        static let missingImportant    = 15.0
        static let trendWorsening      = 20.0
        static let trendImproving      = -10.0
        static let stableGoodDiscount  = -20.0
        static let staleFreshnessBonus = 10.0
        static let frictionPenaltyHigh = 5.0
    }

    // MARK: - Friction (how annoying the metric is to track; higher = penalize bringing it up)

    static let frictionByDomain: [HealthDomain: Double] = [
        .bloodPressure:   0.6,   // cuff required
        .nicotine:        0.0,   // 1 tap
        .cardio:          0.0,   // HK auto
        .strength:        0.1,   // 1 tap
        .bodyComposition: 0.4,   // scale/tape needed
        .sleep:           0.0,   // HK auto
        .alcohol:         0.1,
        .protein:         0.1,
        .fiber:           0.1,
        .omega3:          0.1,
        .dental:          0.1,
        .bloodwork:       0.9,   // lab draw + cost
    ]

    // MARK: - Blood pressure thresholds (mmHg, average across recent readings)

    enum BP {
        static let borderlineSystolicMin: Double = 120
        static let badSystolicMin: Double       = 130
        static let badDiastolicMin: Double      = 80
        static let urgentSystolicMin: Double    = 180
        static let urgentDiastolicMin: Double   = 120

        static let baselineReadingsNeeded = 3
        static let recentWindowDays       = 14
        static let priorWindowDays        = 56
        static let stableHistoryDays      = 90
    }

    // MARK: - Cardio targets

    enum Cardio {
        static let goodWeeklyExerciseMinutes: Double   = 150
        static let borderlineWeeklyExerciseMinutes: Double = 75
        static let goodWeeklyWorkouts: Int             = 3
        static let borderlineWeeklyWorkouts: Int       = 2
        static let goodDailyStepsAverage: Double       = 7500
        static let borderlineDailyStepsAverage: Double = 5000
        static let stalenessDays: Int                  = 3
    }

    // MARK: - Strength targets

    enum Strength {
        static let goodWeeklySessions: Int       = 2
        static let borderlineWeeklySessions: Int = 1
        static let lookbackDays: Int             = 7
        static let stalenessDays: Int            = 14
    }

    // MARK: - Sleep targets

    enum Sleep {
        static let goodHoursLow: Double          = 7.0
        static let goodHoursHigh: Double         = 9.0
        static let badHoursMax: Double           = 6.0
        static let lookbackDays: Int             = 14
        static let stalenessDays: Int            = 3
    }

    // MARK: - Body composition

    enum BodyComp {
        static let weightChangePercentBorderline: Double = 0.03
        static let weightChangePercentBad: Double        = 0.05
        static let lookbackDays: Int                = 90
        static let stalenessDays: Int               = 60
    }

    // MARK: - Habit-style thresholds (yes-days per 7-day window)

    enum Habit {
        static let goodDaysPerWeek: Int       = 5
        static let borderlineDaysPerWeek: Int = 3
        static let lookbackDays: Int          = 7
        static let stalenessDays: Int         = 7
    }

    // MARK: - Omega-3 (weekly, lower frequency than habits above)

    enum Omega3 {
        static let goodPerWeek: Int       = 2
        static let borderlinePerWeek: Int = 1
        static let lookbackDays: Int      = 14
        static let stalenessDays: Int     = 14
    }

    // MARK: - Alcohol classification (last 14 days)

    enum Alcohol {
        static let heavyEpisodesBadThreshold: Int      = 2
        static let lightEpisodesBorderlineThreshold: Int = 5
        static let lookbackDays: Int                   = 14
        static let stalenessDays: Int                  = 14
    }

    // MARK: - Trend-detection windows

    enum Trend {
        static let shortDays: Int = 7
        static let mediumDays: Int = 28
        static let longDays: Int   = 90
        static let minSamplesForTrend: Int = 3
        static let meaningfulRelativeChange: Double = 0.05
    }

    // MARK: - Reminder selection

    enum Reminders {
        static let bpUrgent: ReminderFrequency      = .daily
        static let bpBad: ReminderFrequency         = .fewDays
        static let bpBorderline: ReminderFrequency  = .weekly
        static let bpGoodWithBaseline: ReminderFrequency = .quarterly
        static let bpGoodNoBaseline: ReminderFrequency   = .weekly
        static let bpMissing: ReminderFrequency     = .fewDays

        static let cardioBad: ReminderFrequency     = .weekly
        static let cardioBorderline: ReminderFrequency = .weekly
        static let cardioGood: ReminderFrequency    = .monthly
        static let cardioMissing: ReminderFrequency = .weekly

        static let strengthBad: ReminderFrequency       = .weekly
        static let strengthBorderline: ReminderFrequency = .weekly
        static let strengthGood: ReminderFrequency      = .monthly
        static let strengthMissing: ReminderFrequency   = .weekly

        static let habitBad: ReminderFrequency      = .weekly
        static let habitBorderline: ReminderFrequency = .weekly
        static let habitGood: ReminderFrequency     = .monthly
        static let habitMissing: ReminderFrequency  = .weekly

        static let dentalDefault: ReminderFrequency = .rare
        static let nicotineDefault: ReminderFrequency = .monthly

        // Bloodwork: never more than yearly (expensive). Triennial when everything looks clean.
        static let bloodworkBad: ReminderFrequency        = .annual
        static let bloodworkBorderline: ReminderFrequency = .annual
        static let bloodworkGood: ReminderFrequency       = .triennial
        static let bloodworkMissing: ReminderFrequency    = .annual
    }

    enum Bloodwork {
        // Once a year is the absolute upper bound — no recheck recommendation within this many days
        // of the most recent draw, even if results were bad.
        static let minDaysBetweenDraws: Int = 365
    }

    // MARK: - Nutrition targets (weekly category metrics)

    enum Nutrition {
        // Weekly window — "30 plants a week" framing (Sonnenburg/Spector).
        static let rollupDays: Int = 7
        static let minDaysWithDataForRollup: Int = 3

        // "More is better" weekly targets.
        static let plantsPerWeekTarget: Double            = 30
        static let leafyGreenDaysPerWeekTarget: Double    = 5
        static let omega3DaysPerWeekTarget: Double        = 3
        static let fermentedDaysPerWeekTarget: Double     = 3
        static let legumeDaysPerWeekTarget: Double        = 4

        // "Less is better" weekly limits.
        static let ultraProcessedMealsPerWeekLimit: Double = 3
        static let processedMeatMealsPerWeekLimit: Double  = 2
        static let friedMealsPerWeekLimit: Double          = 2

        // Status thresholds as fraction of target / limit.
        // For "more is better": % of target. For "less is better": % of limit.
        static let lowFraction: Double  = 0.50
        static let veryLowFraction: Double = 0.30
        static let okMinFraction: Double = 0.80
        static let okMaxFraction: Double = 1.00
        static let highFraction: Double = 1.20
        static let veryHighFraction: Double = 1.50
    }

    // MARK: - OpenRouter / vision LLM

    enum OpenRouter {
        // Default model. OpenRouter accepts model IDs of the form "anthropic/claude-sonnet-4.6".
        // If your OpenRouter account exposes a different variant, change this string here.
        static let defaultModel = "anthropic/claude-sonnet-4.6"

        // Pricing per million tokens (USD). Adjust when official pricing changes.
        // Sonnet 4.6 standard rates as of late 2025.
        static let inputUSDPerMillion: Double  = 3.00
        static let outputUSDPerMillion: Double = 15.00

        static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        static let httpReferer = "https://github.com/fabian-kir/longevity-compass"
        static let appTitle    = "Longevity Compass"

        // Image-output model used for auto-generated exercise icons.
        // Must support chat-completions image+text output modalities on OpenRouter.
        // Each image ~1290 image-output tokens → roughly $0.04 per icon.
        static let imageModel = "google/gemini-2.5-flash-image"
        static let imageInputUSDPerMillion:  Double = 0.30
        static let imageOutputUSDPerMillion: Double = 30.00
    }

    // MARK: - Biological age estimation
    //
    // Proxy model: start from chronological age, then add or subtract years per input.
    // Weights are calibrated against published associations (VO2 max → mortality risk,
    // HbA1c/CRP bands, BP categories, etc.) — they are deliberately conservative.
    // Each contributor is capped so a single noisy value can't dominate the estimate.

    enum BioAge {

        // MARK: - V2 (new aggregation engine; wired up in Task 3+)
        //
        // Reference means, SDs, freshness windows, per-signal `yearsPerSD`,
        // and per-factor caps for the rewritten biological-age engine.
        // Logic helpers (`zScore`, `interpolateDecadeNorm`) live in
        // `BiologicalAgeEngine.swift` next to the new type scaffolding.
        enum V2 {

            /// Reference means/SDs for v2 biological-age scoring.
            ///
            /// Numbers are rough population midpoints drawn from common references
            /// (NHANES, Cooper/ACSM tables, KDIGO eGFR, Ridker hs-CRP, Apple Watch
            /// HRV literature). They are not calibrated against mortality endpoints.
            /// Source-specific citations live in docs/biological-age-methodology.md
            /// (Task 10). When tightening calibration later, update both here and
            /// in the methodology doc together.

            // MARK: - Reference: VO2 max (ml/kg/min)
            // Source: Cooper Institute / ACSM population reference tables.
            /// Cooper Institute / ACSM male VO2 max population midpoints.
            static let vo2NormsMale: [Int: Double] = [
                20: 48, 30: 44, 40: 40, 50: 36, 60: 32, 70: 28,
            ]
            /// Cooper Institute / ACSM female VO2 max population midpoints.
            static let vo2NormsFemale: [Int: Double] = [
                20: 40, 30: 37, 40: 34, 50: 31, 60: 28, 70: 25,
            ]
            /// Pooled SD of VO2 max across adult age decades (ml/kg/min).
            /// Source: ACSM / FRIEND registry tables.
            static let vo2MaxSD: Double = 7

            // MARK: - Reference: HRV (SDNN, Apple Watch, ms)
            /// Apple Watch HRV SDNN decade midpoints (male). Derived from published
            /// Apple Watch HRV literature (Naschitz et al., Apple Heart Study derivatives).
            static let hrvNormsMale: [Int: Double] = [
                20: 55, 30: 48, 40: 40, 50: 34, 60: 28, 70: 24,
            ]
            /// Apple Watch HRV SDNN decade midpoints (female). Same source as male table.
            static let hrvNormsFemale: [Int: Double] = [
                20: 52, 30: 45, 40: 38, 50: 32, 60: 27, 70: 23,
            ]
            /// Pooled SD across age decades for Apple Watch SDNN (ms).
            static let hrvSD: Double = 14

            // MARK: - Reference: Resting HR (bpm), age-flat
            /// Healthy-adult RHR population midpoint. Source: NHANES adult means.
            static let rhrMean: Double = 65
            /// Pooled adult RHR SD. Source: NHANES.
            static let rhrSD: Double = 10

            // MARK: - Reference: Glycemic
            /// Non-diabetic adult HbA1c midpoint (%). Source: NHANES.
            static let hba1cMean: Double = 5.3
            /// HbA1c SD in non-diabetic adults. Source: NHANES.
            static let hba1cSD: Double = 0.3
            /// Fasting glucose midpoint (mg/dL). Source: NHANES non-diabetic adults.
            static let fastingGlucoseMean: Double = 90
            /// Fasting glucose SD (mg/dL). Source: NHANES non-diabetic adults.
            static let fastingGlucoseSD: Double = 8
            /// Fasting insulin midpoint (µU/mL) for normo-glycemic adults.
            static let fastingInsulinMean: Double = 7
            /// Fasting insulin SD (µU/mL).
            static let fastingInsulinSD: Double = 3
            /// HOMA-IR alternative midpoint (use when the upstream pipeline feeds HOMA-IR
            /// in place of raw insulin).
            static let homaIRMean: Double = 1.5
            /// HOMA-IR alternative SD.
            static let homaIRSD: Double = 0.8
            /// HOMA-IR formula: glucose[mg/dL] × insulin[µU/mL] / 405.
            static let homaIRDenominator: Double = 405
            /// HOMA-IR plausibility window (inclusive). Values outside collapse
            /// `qualityWeight` to 0 so a lab error can't poison the insulin slot.
            static let homaIRPlausibilityMin: Double = 0.1
            static let homaIRPlausibilityMax: Double = 50

            // MARK: - Reference: Lipids
            /// ApoB midpoint (mg/dL). Source: NHANES adult midpoint.
            static let apoBMean: Double = 95
            /// ApoB SD (mg/dL). Source: NHANES.
            static let apoBSD: Double = 22
            /// LDL-C midpoint (mg/dL). Source: NHANES adult midpoint.
            static let ldlMean: Double = 115
            /// LDL-C SD (mg/dL). Source: NHANES.
            static let ldlSD: Double = 28
            /// HDL-C male midpoint (mg/dL). Source: NHANES adult midpoint.
            static let hdlMaleMean: Double = 48
            /// HDL-C male SD (mg/dL). Source: NHANES.
            static let hdlMaleSD: Double = 12
            /// HDL-C female midpoint (mg/dL). Source: NHANES adult midpoint.
            static let hdlFemaleMean: Double = 58
            /// HDL-C female SD (mg/dL). Source: NHANES.
            static let hdlFemaleSD: Double = 14
            /// Triglyceride/HDL ratio midpoint (mg/dL units).
            static let trigHdlRatioMean: Double = 2.0
            /// Triglyceride/HDL ratio SD (mg/dL units).
            static let trigHdlRatioSD: Double = 1.2

            // MARK: - Reference: Hemodynamic (BP, mmHg)
            /// Systolic BP midpoint (mmHg). Source: NHANES adult midpoint.
            static let systolicBPMean: Double = 122
            /// Systolic BP SD. Source: NHANES.
            static let systolicBPSD: Double = 12
            /// Diastolic BP midpoint (mmHg). Source: NHANES adult midpoint.
            static let diastolicBPMean: Double = 78
            /// Diastolic BP SD. Source: NHANES.
            static let diastolicBPSD: Double = 8

            // MARK: - Reference: Inflammation
            /// hs-CRP geometric-mean midpoint expressed in log10(mg/L). 0.0 ↔ 1.0 mg/L.
            /// Source: Ridker / JUPITER population geometric means.
            static let hsCrpLog10Mean: Double = 0.0
            /// hs-CRP log10(mg/L) SD. Source: Ridker / JUPITER.
            static let hsCrpLog10SD: Double = 0.45
            /// Homocysteine midpoint (µmol/L). Source: NHANES adult midpoint.
            static let homocysteineMean: Double = 9
            /// Homocysteine SD (µmol/L). Source: NHANES.
            static let homocysteineSD: Double = 3

            // MARK: - Reference: Organ (eGFR, ALT)
            /// Age-anchored eGFR norms (mL/min/1.73m²). Decade-keyed midpoints from
            /// KDIGO 2024 eGFR reference / general nephrology references. Lower values
            /// are expected with age, so direction handling lives in the engine.
            static let eGFRNorms: [Int: Double] = [
                20: 105, 30: 100, 40: 95, 50: 90, 60: 85, 70: 78,
            ]
            /// Pooled SD for adult eGFR (mL/min/1.73m²). Source: KDIGO references.
            static let eGFRSD: Double = 15
            /// ALT male midpoint (U/L). Source: NHANES adult midpoint.
            static let altMaleMean: Double = 27
            /// ALT male SD (U/L). Source: NHANES.
            static let altMaleSD: Double = 11
            /// ALT female midpoint (U/L). Source: NHANES adult midpoint.
            static let altFemaleMean: Double = 22
            /// ALT female SD (U/L). Source: NHANES.
            static let altFemaleSD: Double = 9

            // MARK: - Reference: Body composition
            /// Waist circumference male midpoint (cm). Source: NHANES adult midpoint.
            static let waistMaleMean: Double = 94
            /// Waist male SD. Source: NHANES.
            static let waistMaleSD: Double = 12
            /// Waist circumference female midpoint (cm). Source: NHANES adult midpoint.
            static let waistFemaleMean: Double = 80
            /// Waist female SD. Source: NHANES.
            static let waistFemaleSD: Double = 11
            /// Expected 90-day percent weight change for a stable adult (0% mean).
            /// Most adults are weight-stable.
            static let weightTrendMean: Double = 0.0
            /// 90-day percent weight change SD.
            static let weightTrendSD: Double = 2.5

            // MARK: - Reference: Behavior
            /// Sleep midpoint (h/night). Source: CDC adult averages.
            static let sleepMean: Double = 7.5
            /// Sleep SD (h/night). Source: CDC adult averages.
            static let sleepSD: Double = 1.0
            /// Weekly exercise-minutes midpoint. Source: WHO/ACSM guideline anchor (150 min/wk).
            static let exerciseMinutesMean: Double = 150
            /// Weekly exercise-minutes SD.
            static let exerciseMinutesSD: Double = 120
            /// Strength sessions per week midpoint. Most adults ~1/wk.
            static let strengthSessionsMean: Double = 1.0
            /// Strength sessions per week SD.
            static let strengthSessionsSD: Double = 1.0
            /// Daily steps midpoint. Source: large smartphone/wearable population studies.
            static let dailyStepsMean: Double = 6500
            /// Daily steps SD. Source: large wearable population studies.
            static let dailyStepsSD: Double = 3000

            // MARK: - Lifestyle flat penalties (years; sign handled in aggregation)
            /// Active nicotine use penalty (years added to bio-age). Source: clinical bio-age literature.
            static let nicotineActiveYears: Double = 5
            /// Reward for documented clean nicotine log (years subtracted).
            static let nicotineCleanYears: Double = -1
            /// Heavy-drinking pattern penalty (years). Heavy = 2+ heavy days in last 14.
            static let alcoholHeavyYears: Double = 2
            /// Frequent-drinking pattern penalty (years). Frequent = 5+ drinking days in last 14.
            static let alcoholFrequentYears: Double = 1
            /// Reward for documented alcohol-free 14d window (years subtracted).
            static let alcoholNoneYears: Double = -0.5

            // MARK: - Freshness windows
            /// VO2 max full-weight window (days). Linear decay from this point to `vo2DecayDays`.
            static let vo2FreshDays: Int = 60
            /// VO2 max zero-weight horizon (days). Beyond this, freshness weight is 0.
            static let vo2DecayDays: Int = 180

            /// Minimum days of HRV samples in last 28 to count the signal.
            static let hrvMinDays: Int = 14
            /// Minimum days of RHR samples in last 28 to count the signal.
            static let rhrMinDays: Int = 14

            // MARK: - HRV noise handling (continuous-time EWMA)
            //
            // Apple Watch SDNN is single-night noisy: a poor night can swing the
            // raw value 20%+ even when underlying autonomic state has not
            // changed. We treat the noisy time-series x(t) as the output of a
            // first-order low-pass filter:
            //
            //     ds/dt = (x − s) / τ
            //
            // discretised at each incoming sample with Δt = time since the
            // previous sample:
            //
            //     β     = 1 − exp(−Δt / τ)
            //     s_new = β·x_new + (1−β)·s_prev
            //     τ     = halfLife / ln(2)
            //
            // This is the density-aware (non-uniform-grid) EWMA: a half-life
            // expressed in REAL DAYS, not sample count. Multiple samples on the
            // same night each contribute a small β·x_new nudge instead of all
            // collapsing to a single daily mean; gaps after missing nights
            // automatically raise β so the next sample carries more weight
            // (correct — the prior estimate has aged).
            //
            // Half-life 7 days → τ ≈ 10.1 days → β at Δt=1d ≈ 0.093.

            /// Half-life of the HRV EWMA smoother, in real days.
            /// A sample N days old contributes 0.5^(N/halfLife) of its weight
            /// to the current estimate. 7 days picked to absorb single-night
            /// jitter while still responding to genuine multi-week shifts.
            static let hrvEWMAHalfLifeDays: Double = 7.0

            /// Lookback window for raw HRV samples requested from HealthKit.
            /// Wider than necessary for the smoother's effective memory so a
            /// sparse user (few samples per week) still accumulates enough
            /// samples to leave the warm-up regime.
            static let hrvSeriesLookbackDays: Int = 60

            /// Minimum number of raw HRV samples in the lookback window
            /// required before the engine uses the smoothed estimate. Below
            /// this, the engine falls back to the existing 28d mean — the
            /// smoother needs enough samples to escape its warm-up bias.
            static let hrvEWMAMinSamples: Int = 6

            /// Bloodwork freshness: full weight if drawn within this many months.
            static let bloodworkFullMonths: Int = 6
            /// Bloodwork freshness: half weight if drawn within this many months.
            static let bloodworkHalfMonths: Int = 12
            /// Bloodwork freshness: quarter weight if drawn within this many months.
            /// Beyond this horizon the signal is dropped.
            static let bloodworkQuarterMonths: Int = 24

            /// Minimum body-weight measurements within the 90-day window required to
            /// score the `weightTrend` signal.
            static let weightSeriesMinPoints: Int = 6

            /// Look-back window for nicotine status (days).
            static let nicotineWindowDays: Int = 60
            /// Look-back window for alcohol pattern (days).
            static let alcoholWindowDays: Int = 14
            /// 90-day trend window — used for VO2-then, RHR baseline, body-mass drift.
            static let trendWindowDays: Int = 90
        }

        // MARK: - Trend thresholds (still used by the v2 90-day trend mapping)
        //
        // Threshold for what counts as a meaningful 90-day biological-age
        // change. The v2 engine computes the delta in continuous z-score-driven
        // years; these constants decide when to surface that as
        // improving/worsening vs stable.
        static let trendImprovingThreshold: Double = -0.3
        static let trendWorseningThreshold: Double = 0.3
    }

    // MARK: - Dashboard policy

    enum Dashboard {
        static let topPriorityCount: Int        = 3
        static let highPriorityScoreCutoff: Double = 110   // any item ≥ this counts as "high priority"
        static let needsAttentionScoreCutoff: Double = 70
        // Domains considered high-impact (must be good/missing-low-importance for lower-priority items to surface)
        static let highImpactDomains: Set<HealthDomain> = [
            .bloodPressure, .nicotine, .cardio, .strength, .bodyComposition, .sleep, .bloodwork,
        ]
    }
}
