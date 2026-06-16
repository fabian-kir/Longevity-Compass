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
        static let goodSystolicMax: Double      = 119
        static let goodDiastolicMax: Double     = 79
        static let borderlineSystolicMin: Double = 120
        static let borderlineSystolicMax: Double = 129
        static let badSystolicMin: Double       = 130
        static let badDiastolicMin: Double      = 80
        static let urgentSystolicMin: Double    = 180
        static let urgentDiastolicMin: Double   = 120

        static let baselineReadingsNeeded = 3
        static let baselineWindowDays     = 14
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
        static let borderlineHoursLow: Double    = 6.0
        static let badHoursMax: Double           = 6.0
        static let lookbackDays: Int             = 14
        static let stalenessDays: Int            = 3
    }

    // MARK: - Body composition

    enum BodyComp {
        static let waistChangeBorderlineCm: Double = 2.0
        static let waistChangeBadCm: Double        = 5.0
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

        // Cheap image-output model used for auto-generated exercise icons.
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
        // VO2 max age-norms (ml/kg/min), rough midpoints from population reference tables.
        // Keyed by decade-of-life floor (e.g. 30 covers 30–39). Capped at 70.
        static let vo2NormsMale: [Int: Double] = [
            20: 48, 30: 44, 40: 40, 50: 36, 60: 32, 70: 28,
        ]
        static let vo2NormsFemale: [Int: Double] = [
            20: 40, 30: 37, 40: 34, 50: 31, 60: 28, 70: 25,
        ]
        /// One MET ≈ 3.5 ml/kg/min. ~1 year of biological age per 2 ml/kg/min above/below norm.
        static let vo2YearsPerUnitDelta: Double = 0.5
        static let vo2MaxDelta: Double = 6

        // Resting HR (bpm) → years
        static let rhrYearsMap: [(maxValue: Double, years: Double)] = [
            (55, -2), (60, -1), (66, 0), (72, 1), (78, 2), (.infinity, 3),
        ]

        // HbA1c (%) → years
        static let hba1cYearsMap: [(maxValue: Double, years: Double)] = [
            (5.0, -1), (5.5, 0), (5.7, 1), (6.0, 2), (6.5, 3), (.infinity, 5),
        ]

        // hs-CRP (mg/L) → years
        static let crpYearsMap: [(maxValue: Double, years: Double)] = [
            (1.0, -1), (3.0, 1), (10.0, 3), (.infinity, 3),
        ]

        // ApoB (mg/dL) → years; LDL-C used as fallback with same buckets.
        static let apoBYearsMap: [(maxValue: Double, years: Double)] = [
            (70, -1), (90, 0), (110, 1), (130, 2), (.infinity, 3),
        ]
        static let ldlYearsMap: [(maxValue: Double, years: Double)] = [
            (80, -1), (100, 0), (130, 1), (160, 2), (.infinity, 3),
        ]

        // Blood pressure (systolic, diastolic averages) → years
        // Optimal <120/<80 = -1; elevated 120–129/<80 = +1; stage 1 130–139/80–89 = +2; stage 2 ≥140/≥90 = +3.
        static let bpOptimalYears: Double  = -1
        static let bpElevatedYears: Double = 1
        static let bpStage1Years: Double   = 2
        static let bpStage2Years: Double   = 3
        static let bpUrgentYears: Double   = 5

        // Waist circumference (cm) → years
        static let waistMaleLow: Double    = 94
        static let waistMaleHigh: Double   = 102
        static let waistFemaleLow: Double  = 80
        static let waistFemaleHigh: Double = 88

        // Sleep (h/night, 7d avg) → years
        static let sleepGoodYears: Double      = -1   // 7–9 h
        static let sleepBorderlineYears: Double = 0   // 6–7 h or 9–10 h
        static let sleepBadYears: Double       = 2   // <6 h chronic

        // Weekly exercise minutes → years
        static let exerciseGoodMinutes: Double     = 300
        static let exerciseAdequateMinutes: Double = 150
        static let exerciseLowMinutes: Double      = 75
        static let exerciseGoodYears: Double       = -2
        static let exerciseAdequateYears: Double   = -1
        static let exerciseLowYears: Double        = 1
        static let exerciseSedentaryYears: Double  = 2

        // Strength sessions per week → years
        static let strengthGoodSessions: Int = 2
        static let strengthYearsGood: Double = -1
        static let strengthYearsNone: Double = 1

        // Lifestyle modifiers
        static let nicotineActiveYears: Double = 5
        static let alcoholHeavyYears: Double   = 2
        static let alcoholFrequentYears: Double = 1
        static let alcoholNoneYears: Double    = -0.5

        // Nutrition (very small signal — diet effects already partly captured via BP/lipids/HbA1c)
        static let nutritionGoodYears: Double = -0.5
        static let nutritionPoorYears: Double = 0.5

        // Confidence: how many primary inputs are present.
        // Primary set: VO2 max, RHR, BP, HbA1c, hs-CRP, ApoB-or-LDL, waist-or-weight, sleep, exercise.
        static let primaryInputCount: Int = 9

        // Trend: meaningful 90-day delta in years
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
