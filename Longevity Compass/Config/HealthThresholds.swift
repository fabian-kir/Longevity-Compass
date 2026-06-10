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
    }

    // MARK: - Nutrition targets (per day unless noted)

    enum Nutrition {
        static let proteinGramsTarget: Double      = 70    // ~1 g/kg for 70 kg adult; rough
        static let fiberGramsTarget: Double        = 28    // WHO ≥25–30 g/day
        static let addedSugarGramsLimit: Double    = 25    // WHO ≤25 g/day for adults
        static let saturatedFatGramsLimit: Double  = 22    // ≈10% of a 2000 kcal/day diet
        static let sodiumMilligramsLimit: Double   = 2300  // FDA / WHO upper bound
        static let leafyGreensServingsTarget: Double = 1.0 // 1 cup raw / 0.5 cup cooked per day
        static let fattyFishServingsPerWeekTarget: Double = 2.0
        static let ultraProcessedTargetMax: Double = 0.35  // 0=whole, 1=ultra-processed; aim ≤0.35
        static let eatingOccasionsPerDayMax: Double = 4.0  // soft ceiling — frequent snacking flag

        static let rollupDays: Int = 14
        static let minDaysWithDataForRollup: Int = 3

        // Status thresholds expressed as fraction of target.
        // For "more is better" buckets (protein, fibre, leafy greens, fatty fish): % of target.
        // For "less is better" buckets (sugar, sat fat, sodium, ultra-processed, occasions): % of limit.
        static let lowFraction: Double  = 0.50  // <50% of target → low (or very-low)
        static let veryLowFraction: Double = 0.30
        static let okMinFraction: Double = 0.80 // 80%+ → on target for "more is better"
        static let okMaxFraction: Double = 1.00 // for "less is better": ≤ limit = ok
        static let highFraction: Double = 1.20  // >120% of limit → high
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
    }

    // MARK: - Dashboard policy

    enum Dashboard {
        static let topPriorityCount: Int        = 3
        static let highPriorityScoreCutoff: Double = 110   // any item ≥ this counts as "high priority"
        static let needsAttentionScoreCutoff: Double = 70
        // Domains considered high-impact (must be good/missing-low-importance for lower-priority items to surface)
        static let highImpactDomains: Set<HealthDomain> = [
            .bloodPressure, .nicotine, .cardio, .strength, .bodyComposition, .sleep,
        ]
    }
}
