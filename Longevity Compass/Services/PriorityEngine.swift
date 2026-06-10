import Foundation

enum PriorityEngine {

    struct Result {
        let allItems: [PriorityItem]
        let topItems: [PriorityItem]
        let overallStatus: OverallStatus
        let generatedAt: Date
    }

    // MARK: - Entry point

    static func evaluate(
        manualEntries: [ManualEntry],
        nutritionEntries: [NutritionEntry] = [],
        healthSnapshot: HealthKitSnapshot,
        now: Date = .now
    ) -> Result {

        let digest = NutritionEngine.digest(nutritionEntries, now: now)

        let items: [PriorityItem] = HealthDomain.allCases.map { domain in
            switch domain {
            case .bloodPressure:    evaluateBloodPressure(manualEntries, healthSnapshot, now: now)
            case .nicotine:         evaluateNicotine(manualEntries, now: now)
            case .cardio:           evaluateCardio(healthSnapshot, now: now)
            case .strength:         evaluateStrength(manualEntries, healthSnapshot, now: now)
            case .bodyComposition:  evaluateBodyComposition(healthSnapshot, now: now)
            case .sleep:            evaluateSleep(healthSnapshot, now: now)
            case .alcohol:          evaluateAlcohol(manualEntries, now: now)
            case .protein:          evaluateNutritionDomain(.protein, bucket: .protein, digest: digest, fallbackEntries: manualEntries, fallbackType: .proteinHabit, now: now)
            case .fiber:            evaluateNutritionDomain(.fiber, bucket: .fiber, digest: digest, fallbackEntries: manualEntries, fallbackType: .fiberHabit, now: now)
            case .omega3:           evaluateNutritionDomain(.omega3, bucket: .fattyFish, digest: digest, fallbackEntries: manualEntries, fallbackType: .omega3Habit, now: now)
            case .dental:           evaluateDental(manualEntries, now: now)
            }
        }

        let sortedAll = items.sorted { $0.priorityScore > $1.priorityScore }
        let topItems = selectTopItems(from: sortedAll)
        let overall = computeOverallStatus(items: items)

        return Result(allItems: sortedAll, topItems: topItems, overallStatus: overall, generatedAt: now)
    }

    // MARK: - Top-item filtering

    private static func selectTopItems(from sorted: [PriorityItem]) -> [PriorityItem] {
        let highImpact = HealthThresholds.Dashboard.highImpactDomains
        let anyHighImpactOffTrack = sorted.contains {
            highImpact.contains($0.domain) &&
            ($0.status == .bad || $0.status == .urgent || $0.status == .borderline || $0.dataIsStale)
        }

        let candidates: [PriorityItem]
        if anyHighImpactOffTrack {
            candidates = sorted.filter { highImpact.contains($0.domain) || $0.status == .urgent }
        } else {
            candidates = sorted
        }

        // Only include items that actually warrant attention.
        let warranted = candidates.filter {
            $0.status != .good || $0.dataIsStale
        }

        return Array(warranted.prefix(HealthThresholds.Dashboard.topPriorityCount))
    }

    private static func computeOverallStatus(items: [PriorityItem]) -> OverallStatus {
        let highImpact = HealthThresholds.Dashboard.highImpactDomains
        if items.contains(where: { $0.status == .urgent }) { return .highPriority }
        if items.contains(where: { highImpact.contains($0.domain) && $0.status == .bad }) {
            return .highPriority
        }
        if items.contains(where: { highImpact.contains($0.domain) && $0.status == .borderline }) {
            return .needsAttention
        }
        if items.contains(where: { $0.status == .bad }) { return .needsAttention }
        return .onTrack
    }

    // MARK: - Score assembly

    private static func score(
        domain: HealthDomain,
        status: DomainStatus,
        trend: TrendDirection,
        isStableGoodLongTerm: Bool,
        isStale: Bool
    ) -> Double {
        let base = HealthThresholds.impactWeight(domain)

        let risk: Double = switch status {
        case .urgent:     HealthThresholds.Score.riskUrgent
        case .bad:        HealthThresholds.Score.riskBad
        case .borderline: HealthThresholds.Score.riskBorderline
        case .missing:    HealthThresholds.Score.missingImportant
        case .good:       HealthThresholds.Score.riskGood
        case .unknown:    HealthThresholds.Score.missingImportant
        }

        let trendDelta: Double = switch trend {
        case .worsening: HealthThresholds.Score.trendWorsening
        case .improving: HealthThresholds.Score.trendImproving
        default: 0
        }

        let stability = (isStableGoodLongTerm && status == .good) ? HealthThresholds.Score.stableGoodDiscount : 0
        let staleness = isStale ? HealthThresholds.Score.staleFreshnessBonus : 0
        let friction  = (HealthThresholds.frictionByDomain[domain] ?? 0) * HealthThresholds.Score.frictionPenaltyHigh

        return base + risk + trendDelta + stability + staleness - friction
    }

    private static func nextTrackingDate(
        from lastDate: Date?,
        frequency: ReminderFrequency,
        status: DomainStatus,
        now: Date
    ) -> Date? {
        if status == .missing || status == .urgent { return now }
        guard let days = frequency.days else { return nil }
        let base = lastDate ?? now
        return Calendar.current.date(byAdding: .day, value: days, to: base)
    }

    // MARK: - Blood Pressure

    private static func evaluateBloodPressure(
        _ entries: [ManualEntry],
        _ snapshot: HealthKitSnapshot,
        now: Date
    ) -> PriorityItem {

        // Merge manual + HK readings into one list.
        var readings: [BloodPressureReading] = snapshot.bloodPressureReadings
        let manualBP = entries.filter { $0.entryType == .bloodPressure }
        for entry in manualBP {
            guard let sys = entry.primaryValue, let dia = entry.secondaryValue else { continue }
            readings.append(BloodPressureReading(systolic: sys, diastolic: dia, date: entry.date))
        }
        readings.sort { $0.date > $1.date }

        // Windows
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -HealthThresholds.BP.recentWindowDays, to: now) ?? now
        let priorCutoff  = Calendar.current.date(byAdding: .day, value: -(HealthThresholds.BP.recentWindowDays + HealthThresholds.BP.priorWindowDays), to: now) ?? now
        let stableCutoff = Calendar.current.date(byAdding: .day, value: -HealthThresholds.BP.stableHistoryDays, to: now) ?? now
        let urgentCutoff = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now

        let recent = readings.filter { $0.date >= recentCutoff }
        let prior  = readings.filter { $0.date >= priorCutoff && $0.date < recentCutoff }
        let stableHistory = readings.filter { $0.date >= stableCutoff }
        let urgentReadings = readings.filter { $0.date >= urgentCutoff }

        // Status
        var status: DomainStatus = .missing
        var reason = "No blood-pressure readings yet."
        var currentDesc = "No readings"
        var hasBaseline = recent.count >= HealthThresholds.BP.baselineReadingsNeeded

        let avgSys = TrendAnalyzer.mean(recent.map(\.systolic))
        let avgDia = TrendAnalyzer.mean(recent.map(\.diastolic))

        if let urgent = urgentReadings.first(where: {
            $0.systolic >= HealthThresholds.BP.urgentSystolicMin || $0.diastolic >= HealthThresholds.BP.urgentDiastolicMin
        }) {
            status = .urgent
            reason = "A recent reading was \(Int(urgent.systolic))/\(Int(urgent.diastolic)) mmHg. If accurate, this needs prompt medical attention."
            currentDesc = "Most recent: \(Int(urgent.systolic))/\(Int(urgent.diastolic)) mmHg"
        } else if let s = avgSys, let d = avgDia {
            currentDesc = "\(Int(s.rounded()))/\(Int(d.rounded())) mmHg (avg of \(recent.count) recent)"
            if s >= HealthThresholds.BP.badSystolicMin || d >= HealthThresholds.BP.badDiastolicMin {
                status = .bad
                reason = "Recent average is in the high range. Confirm with a few clean readings."
            } else if s >= HealthThresholds.BP.borderlineSystolicMin && d < HealthThresholds.BP.badDiastolicMin {
                status = .borderline
                reason = "Recent average sits in the borderline range."
            } else {
                status = .good
                reason = hasBaseline ? "Recent average is in the healthy range." : "Looks good, but a fuller baseline would confirm the trend."
            }
        }

        // Trend
        let priorSys = TrendAnalyzer.mean(prior.map(\.systolic))
        let trend = TrendAnalyzer.direction(recent: avgSys, prior: priorSys, lowerIsBetter: true)
        let trendDesc = trendDescription(trend, hasRecent: !recent.isEmpty, hasPrior: !prior.isEmpty)

        // Stable long-term?
        let stableLongTerm = stableHistory.count >= 8 &&
            (stableHistory.allSatisfy {
                $0.systolic < HealthThresholds.BP.borderlineSystolicMin &&
                $0.diastolic < HealthThresholds.BP.badDiastolicMin
            })

        // Reminder frequency
        let frequency: ReminderFrequency = switch status {
        case .urgent:     HealthThresholds.Reminders.bpUrgent
        case .bad:        HealthThresholds.Reminders.bpBad
        case .borderline: HealthThresholds.Reminders.bpBorderline
        case .good:       hasBaseline && stableLongTerm ? HealthThresholds.Reminders.bpGoodWithBaseline : HealthThresholds.Reminders.bpGoodNoBaseline
        case .missing:    HealthThresholds.Reminders.bpMissing
        case .unknown:    HealthThresholds.Reminders.bpMissing
        }

        let lastDate = readings.first?.date
        let stalenessDays = frequency.days ?? Int.max
        let isStale = lastDate.map { TrendAnalyzer.daysAgo($0, from: now) > stalenessDays } ?? true

        let nextDate = nextTrackingDate(from: lastDate, frequency: frequency, status: status, now: now)
        let priorityScore = score(domain: .bloodPressure, status: status, trend: trend, isStableGoodLongTerm: stableLongTerm, isStale: isStale)

        return PriorityItem(
            domain: .bloodPressure,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.bloodPressure),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: .bloodPressure, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Cardio

    private static func evaluateCardio(_ snapshot: HealthKitSnapshot, now: Date) -> PriorityItem {
        let exerciseMin = snapshot.exerciseMinutesPerWeek
        let workouts7  = snapshot.workoutsLast7Days ?? 0
        let workouts28 = snapshot.workoutsLast28Days ?? 0
        let steps     = snapshot.dailyStepsAverage7d

        let hasAnyData = exerciseMin != nil || (workouts28 > 0) || steps != nil
        var status: DomainStatus = .missing
        var reason = "Apple Health isn't surfacing cardio data yet."
        var currentDesc = "No data"

        if hasAnyData {
            let goodByExercise = (exerciseMin ?? 0) >= HealthThresholds.Cardio.goodWeeklyExerciseMinutes
            let goodByWorkouts = workouts7 >= HealthThresholds.Cardio.goodWeeklyWorkouts
            let goodBySteps    = (steps ?? 0) >= HealthThresholds.Cardio.goodDailyStepsAverage
            let borderByExercise = (exerciseMin ?? 0) >= HealthThresholds.Cardio.borderlineWeeklyExerciseMinutes
            let borderByWorkouts = workouts7 >= HealthThresholds.Cardio.borderlineWeeklyWorkouts
            let borderBySteps    = (steps ?? 0) >= HealthThresholds.Cardio.borderlineDailyStepsAverage

            if goodByExercise || goodByWorkouts || goodBySteps {
                status = .good
                reason = "You're consistently hitting weekly activity targets."
            } else if borderByExercise || borderByWorkouts || borderBySteps {
                status = .borderline
                reason = "Some activity, but below the weekly target."
            } else {
                status = .bad
                reason = "Very low cardio activity in the last week."
            }
            var parts: [String] = []
            if let m = exerciseMin { parts.append("\(Int(m.rounded())) min/wk") }
            if workouts7 > 0 { parts.append("\(workouts7) workout\(workouts7 == 1 ? "" : "s")/7d") }
            if let s = steps { parts.append("\(Int(s.rounded())) steps/day") }
            currentDesc = parts.isEmpty ? "Some data" : parts.joined(separator: " · ")
        }

        // Trend: workouts/7d × 4 vs workouts in last 28d
        let recentScale = Double(workouts7) * 4
        let priorScale  = Double(workouts28)
        let trend = TrendAnalyzer.direction(recent: recentScale, prior: priorScale, lowerIsBetter: false)
        let trendDesc = trendDescription(trend, hasRecent: workouts7 > 0, hasPrior: workouts28 > 0)

        // Per spec: only remind on worsening trend (or already bad). Quiet when good and stable.
        let frequency: ReminderFrequency = {
            switch (status, trend) {
            case (.bad, _):                  return .weekly
            case (.borderline, .worsening):  return .weekly
            case (.borderline, _):           return .biweekly
            case (.good, .worsening):        return .biweekly
            default:                         return .never
            }
        }()

        let lastWorkoutDate = snapshot.sampledAt  // best-effort proxy
        let isStale = workouts7 == 0 && status != .good
        let nextDate = nextTrackingDate(from: lastWorkoutDate, frequency: frequency, status: status, now: now)

        let priorityScore = score(domain: .cardio, status: status, trend: trend, isStableGoodLongTerm: false, isStale: isStale)

        return PriorityItem(
            domain: .cardio,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.cardio),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: .cardio, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Strength

    private static func evaluateStrength(
        _ entries: [ManualEntry],
        _ snapshot: HealthKitSnapshot,
        now: Date
    ) -> PriorityItem {
        let lookback = HealthThresholds.Strength.lookbackDays
        let since = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now
        let sinceDouble = Calendar.current.date(byAdding: .day, value: -(lookback * 2), to: now) ?? now

        let hkRecent  = snapshot.strengthWorkoutsLast7Days ?? 0
        let hk28      = snapshot.strengthWorkoutsLast28Days ?? 0
        let hkPriorWk = max(0, (hk28 - hkRecent) / 3)   // rough weekly avg of days 8-28
        let manualRecent = TrendAnalyzer.distinctDaysWithYes(entries, type: .strengthTraining, since: since, until: now)
        let manualPrior  = TrendAnalyzer.distinctDaysWithYes(entries, type: .strengthTraining, since: sinceDouble, until: since)

        let recent = hkRecent + manualRecent
        let prior  = hkPriorWk + manualPrior
        let lastEntry = TrendAnalyzer.mostRecent(entries, type: .strengthTraining)?.date
        let hasAnyHistory = (hk28 + manualRecent + manualPrior) > 0

        var status: DomainStatus
        var reason: String
        if recent >= HealthThresholds.Strength.goodWeeklySessions {
            status = .good
            reason = "Consistent strength sessions this week."
        } else if recent >= HealthThresholds.Strength.borderlineWeeklySessions {
            status = .borderline
            reason = "One session this week — one more reaches the target."
        } else if !hasAnyHistory {
            status = .missing
            reason = "No strength workouts in Apple Health yet. Log workouts there and they'll show up here."
        } else {
            status = .bad
            reason = "No strength sessions this week."
        }

        let currentDesc: String = {
            if hkRecent > 0 && manualRecent > 0 {
                return "\(recent) session\(recent == 1 ? "" : "s") (last 7d, HK + manual)"
            } else if hkRecent > 0 {
                return "\(hkRecent) HK workout\(hkRecent == 1 ? "" : "s") (last 7d)"
            } else {
                return "\(recent) session\(recent == 1 ? "" : "s") in last 7d"
            }
        }()
        let trend = TrendAnalyzer.direction(recent: Double(recent), prior: Double(prior), lowerIsBetter: false)
        let trendDesc = trendDescription(trend, hasRecent: recent > 0, hasPrior: prior > 0)

        let frequency: ReminderFrequency = switch status {
        case .bad, .borderline: HealthThresholds.Reminders.strengthBad
        case .good:             HealthThresholds.Reminders.strengthGood
        case .missing, .unknown, .urgent: HealthThresholds.Reminders.strengthMissing
        }

        let isStale = lastEntry.map { TrendAnalyzer.daysAgo($0, from: now) > HealthThresholds.Strength.stalenessDays } ?? true
        let nextDate = nextTrackingDate(from: lastEntry, frequency: frequency, status: status, now: now)
        let priorityScore = score(domain: .strength, status: status, trend: trend, isStableGoodLongTerm: false, isStale: isStale)

        return PriorityItem(
            domain: .strength,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.strength),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: .strength, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Sleep

    private static func evaluateSleep(_ snapshot: HealthKitSnapshot, now: Date) -> PriorityItem {
        let h7  = snapshot.sleepHoursAverage7d
        let h28 = snapshot.sleepHoursAverage28d

        var status: DomainStatus
        var reason: String
        var currentDesc: String

        if let avg = h7 {
            currentDesc = String(format: "%.1f h avg (last 7d)", avg)
            if avg < HealthThresholds.Sleep.badHoursMax {
                status = .bad
                reason = "Recent average is under \(Int(HealthThresholds.Sleep.badHoursMax))h."
            } else if avg < HealthThresholds.Sleep.goodHoursLow {
                status = .borderline
                reason = "A bit short — pulling bedtime forward 30 min would help."
            } else if avg <= HealthThresholds.Sleep.goodHoursHigh {
                status = .good
                reason = "Healthy nightly average."
            } else {
                status = .borderline
                reason = "Average is unusually high — worth checking if you feel recovered."
            }
        } else {
            currentDesc = "No sleep data"
            status = .missing
            reason = "Sleep isn't being tracked in Apple Health on this device."
        }

        let trend = TrendAnalyzer.direction(recent: h7, prior: h28, lowerIsBetter: false)
        let trendDesc = trendDescription(trend, hasRecent: h7 != nil, hasPrior: h28 != nil)

        let frequency: ReminderFrequency = switch status {
        case .bad, .borderline: HealthThresholds.Reminders.habitBad
        case .good:             HealthThresholds.Reminders.habitGood
        case .missing, .unknown, .urgent: HealthThresholds.Reminders.habitMissing
        }

        let isStale = h7 == nil
        let lastDate = snapshot.sampledAt
        let nextDate = nextTrackingDate(from: lastDate, frequency: frequency, status: status, now: now)
        let priorityScore = score(domain: .sleep, status: status, trend: trend, isStableGoodLongTerm: false, isStale: isStale)

        return PriorityItem(
            domain: .sleep,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.sleep),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: .sleep, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Body composition (HK weight only — silent unless trend is worsening)

    private static func evaluateBodyComposition(
        _ snapshot: HealthKitSnapshot,
        now: Date
    ) -> PriorityItem {
        let series = snapshot.bodyMassSeries.sorted { $0.date < $1.date }
        let lookback = HealthThresholds.BodyComp.lookbackDays
        let cutoff = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now

        var status: DomainStatus = .missing
        var reason = "No weight in Apple Health yet. Log a weight in Health when convenient — the app will only nudge you if the trend starts drifting."
        var currentDesc = "No data"
        var trend: TrendDirection = .unknown
        var trendDesc = "—"
        var lastDataDate: Date? = nil
        var dataIsStale = false

        if let latest = series.last {
            lastDataDate = latest.date
            let baselineCandidate = series.first(where: { $0.date <= cutoff })?.value ?? series.first?.value

            if let baseline = baselineCandidate, baseline > 0, series.count >= 2 {
                let change = latest.value - baseline
                let pct = change / baseline
                currentDesc = String(format: "Weight %.1f kg (Δ %+.1f kg over %d d)", latest.value, change, lookback)
                if abs(pct) >= HealthThresholds.BodyComp.weightChangePercentBad {
                    status = change > 0 ? .bad : .borderline
                    trend = change > 0 ? .worsening : .improving
                    reason = change > 0
                        ? "Weight is up notably vs ~3 months ago — worth reviewing the trend."
                        : "Weight is down notably vs ~3 months ago — intentional?"
                } else if abs(pct) >= HealthThresholds.BodyComp.weightChangePercentBorderline {
                    status = change > 0 ? .borderline : .good
                    trend = change > 0 ? .worsening : .improving
                    reason = change > 0 ? "Weight is drifting upward." : "Weight is drifting down."
                } else {
                    status = .good
                    trend = .stable
                    reason = "Weight is stable."
                }
                trendDesc = trendDescription(trend, hasRecent: true, hasPrior: true)
            } else {
                currentDesc = String(format: "Weight %.1f kg", latest.value)
                status = .good
                trend = .unknown
                reason = "Latest weight is in. Trend builds with a few more readings — Apple Health is the place to log them."
                trendDesc = "Need more history"
            }

            // "Stale" means: weight is worsening but the user hasn't logged in a while → surface it.
            if trend == .worsening {
                let staleness = TrendAnalyzer.daysAgo(latest.date, from: now)
                dataIsStale = staleness > HealthThresholds.BodyComp.stalenessDays
            }
        }

        // Per the spec: only schedule reminders when trend is worsening. Stay silent otherwise.
        let frequency: ReminderFrequency = {
            switch (status, trend) {
            case (.bad, _), (.borderline, .worsening): .biweekly
            default: .never
            }
        }()
        let nextDate = nextTrackingDate(from: lastDataDate, frequency: frequency, status: status, now: now)
        let priorityScore = score(domain: .bodyComposition, status: status, trend: trend, isStableGoodLongTerm: false, isStale: dataIsStale)

        return PriorityItem(
            domain: .bodyComposition,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.bodyComposition),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: .bodyComposition, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: dataIsStale
        )
    }

    // MARK: - Habits (protein, fiber)

    private static func evaluateHabit(
        _ entries: [ManualEntry],
        domain: HealthDomain,
        type: ManualEntryType,
        now: Date
    ) -> PriorityItem {
        let lookback = HealthThresholds.Habit.lookbackDays
        let since    = Calendar.current.date(byAdding: .day, value: -lookback, to: now) ?? now
        let priorSince = Calendar.current.date(byAdding: .day, value: -(lookback * 2), to: now) ?? now

        let recent = TrendAnalyzer.distinctDaysWithYes(entries, type: type, since: since, until: now)
        let prior  = TrendAnalyzer.distinctDaysWithYes(entries, type: type, since: priorSince, until: since)
        let lastEntry = TrendAnalyzer.mostRecent(entries, type: type)?.date

        var status: DomainStatus
        var reason: String
        if lastEntry == nil {
            status = .missing
            reason = "Start logging when you hit this habit — yes/no is enough."
        } else if recent >= HealthThresholds.Habit.goodDaysPerWeek {
            status = .good
            reason = "Hitting this habit most days."
        } else if recent >= HealthThresholds.Habit.borderlineDaysPerWeek {
            status = .borderline
            reason = "Closer to consistent would help."
        } else {
            status = .bad
            reason = "Hit on \(recent) of the last \(lookback) days."
        }

        let currentDesc = "\(recent)/\(lookback) days"
        let trend = TrendAnalyzer.direction(recent: Double(recent), prior: Double(prior), lowerIsBetter: false)
        let trendDesc = trendDescription(trend, hasRecent: recent > 0, hasPrior: prior > 0)

        let frequency: ReminderFrequency = switch status {
        case .bad, .borderline: HealthThresholds.Reminders.habitBad
        case .good:             HealthThresholds.Reminders.habitGood
        case .missing, .unknown, .urgent: HealthThresholds.Reminders.habitMissing
        }

        let isStale = lastEntry.map { TrendAnalyzer.daysAgo($0, from: now) > HealthThresholds.Habit.stalenessDays } ?? true
        let nextDate = nextTrackingDate(from: lastEntry, frequency: frequency, status: status, now: now)
        let priorityScore = score(domain: domain, status: status, trend: trend, isStableGoodLongTerm: false, isStale: isStale)

        return PriorityItem(
            domain: domain,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(domain),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: domain, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Omega-3

    private static func evaluateOmega3(_ entries: [ManualEntry], now: Date) -> PriorityItem {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let prior = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now

        let recent = TrendAnalyzer.distinctDaysWithYes(entries, type: .omega3Habit, since: since, until: now)
        let priorCount = TrendAnalyzer.distinctDaysWithYes(entries, type: .omega3Habit, since: prior, until: since)
        let lastEntry = TrendAnalyzer.mostRecent(entries, type: .omega3Habit)?.date

        var status: DomainStatus
        var reason: String
        if lastEntry == nil {
            status = .missing
            reason = "Start logging fatty-fish meals — once a week is fine."
        } else if recent >= HealthThresholds.Omega3.goodPerWeek {
            status = .good
            reason = "Hitting at least two fatty-fish meals a week."
        } else if recent >= HealthThresholds.Omega3.borderlinePerWeek {
            status = .borderline
            reason = "One meal — one more reaches the target."
        } else {
            status = .bad
            reason = "No fatty-fish meals logged this week."
        }

        let currentDesc = "\(recent) meal\(recent == 1 ? "" : "s") in last 7d"
        let trend = TrendAnalyzer.direction(recent: Double(recent), prior: Double(priorCount), lowerIsBetter: false)
        let trendDesc = trendDescription(trend, hasRecent: recent > 0, hasPrior: priorCount > 0)

        let frequency: ReminderFrequency = status == .good ? .biweekly : .weekly
        let isStale = lastEntry.map { TrendAnalyzer.daysAgo($0, from: now) > HealthThresholds.Omega3.stalenessDays } ?? true
        let nextDate = nextTrackingDate(from: lastEntry, frequency: frequency, status: status, now: now)
        let priorityScore = score(domain: .omega3, status: status, trend: trend, isStableGoodLongTerm: false, isStale: isStale)

        return PriorityItem(
            domain: .omega3,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.omega3),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: .omega3, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Nutrition-driven domains (prefer NutritionEntry rollups; fall back to habit toggles)

    private static func evaluateNutritionDomain(
        _ domain: HealthDomain,
        bucket: NutrientBucket,
        digest: NutritionDigest,
        fallbackEntries: [ManualEntry],
        fallbackType: ManualEntryType,
        now: Date
    ) -> PriorityItem {
        // If the rollup has enough data, drive the priority from it.
        if let rollup = digest.rollup(for: bucket), rollup.status != .unknown {
            let status: DomainStatus = {
                switch rollup.status {
                case .veryLow:           return .bad
                case .low:               return .borderline
                case .ok:                return .good
                case .high, .veryHigh:   return .good     // "more is better" for these buckets
                case .unknown:           return .missing
                }
            }()

            let reason: String = {
                switch status {
                case .good:       return rollup.summary
                case .borderline: return rollup.summary
                case .bad:        return rollup.summary
                default:          return rollup.summary
                }
            }()

            let currentDesc: String = {
                guard let avg = rollup.dailyAverage else { return "—" }
                if bucket == .fattyFish { return String(format: "%.1f servings/wk", avg) }
                return String(format: "%.0f %@", avg, bucket.unitSuffix.replacingOccurrences(of: "/day", with: "g/day"))
            }()

            let trendDesc = trendDescription(rollup.trend, hasRecent: rollup.daysWithData >= 3, hasPrior: rollup.daysWithData >= 5)
            let frequency: ReminderFrequency = (status == .bad || status == .borderline) ? .weekly : .never
            let lastDate = now
            let nextDate = nextTrackingDate(from: lastDate, frequency: frequency, status: status, now: now)
            let priorityScore = score(domain: domain, status: status, trend: rollup.trend, isStableGoodLongTerm: false, isStale: false)

            return PriorityItem(
                domain: domain,
                status: status,
                trend: rollup.trend,
                priorityScore: priorityScore,
                impactWeight: HealthThresholds.impactWeight(domain),
                reason: reason,
                currentValueDescription: currentDesc,
                trendDescription: trendDesc,
                recommendedActions: RecommendationEngine.actions(for: domain, status: status),
                nextTrackingDate: nextDate,
                reminderFrequency: frequency,
                dataIsStale: false
            )
        }
        // Fallback: habit-toggle logic from v0.
        switch domain {
        case .omega3:
            return evaluateOmega3(fallbackEntries, now: now)
        default:
            return evaluateHabit(fallbackEntries, domain: domain, type: fallbackType, now: now)
        }
    }

    // MARK: - Alcohol

    private static func evaluateAlcohol(_ entries: [ManualEntry], now: Date) -> PriorityItem {
        let since = Calendar.current.date(byAdding: .day, value: -HealthThresholds.Alcohol.lookbackDays, to: now) ?? now
        let recentAll = entries.filter { $0.entryType == .alcohol && $0.date >= since }
        let heavyCount = recentAll.filter { $0.alcoholLevel == .heavy }.count
        let lightCount = recentAll.filter { $0.alcoholLevel == .light }.count
        let noneCount  = recentAll.filter { $0.alcoholLevel == AlcoholLevel.none }.count
        let lastEntry  = recentAll.max(by: { $0.date < $1.date })?.date

        var status: DomainStatus
        var reason: String
        if recentAll.isEmpty {
            status = .missing
            reason = "Add a quick log on drinking days — even 'none' helps."
        } else if heavyCount >= HealthThresholds.Alcohol.heavyEpisodesBadThreshold {
            status = .bad
            reason = "Multiple heavy episodes in the last 2 weeks."
        } else if (heavyCount + lightCount) >= HealthThresholds.Alcohol.lightEpisodesBorderlineThreshold {
            status = .borderline
            reason = "Frequent drinking days — fewer would help BP and sleep."
        } else {
            status = .good
            reason = "Light or no drinking lately."
        }

        let currentDesc = "Last 14d: \(noneCount) none · \(lightCount) light · \(heavyCount) heavy"
        let trend: TrendDirection = .unknown
        let trendDesc = "—"

        let frequency: ReminderFrequency = status == .good ? .monthly : .weekly
        let isStale = lastEntry.map { TrendAnalyzer.daysAgo($0, from: now) > HealthThresholds.Alcohol.stalenessDays } ?? true
        let nextDate = nextTrackingDate(from: lastEntry, frequency: frequency, status: status, now: now)
        let priorityScore = score(domain: .alcohol, status: status, trend: trend, isStableGoodLongTerm: false, isStale: isStale)

        return PriorityItem(
            domain: .alcohol,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.alcohol),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: .alcohol, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Nicotine

    private static func evaluateNicotine(_ entries: [ManualEntry], now: Date) -> PriorityItem {
        let since = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        let nicotineEntries = entries.filter { $0.entryType == .nicotine && $0.date >= since }
        let usedRecently    = nicotineEntries.contains { $0.booleanValue == true }
        let lastEntry       = nicotineEntries.max(by: { $0.date < $1.date })?.date

        var status: DomainStatus
        var reason: String
        var currentDesc: String

        if usedRecently {
            status = .bad
            reason = "Any nicotine use is the highest-leverage thing to stop. Be honest in logs — it's how progress shows."
            let count = nicotineEntries.filter { $0.booleanValue == true }.count
            currentDesc = "\(count) day\(count == 1 ? "" : "s") logged in last 60d"
        } else if nicotineEntries.isEmpty {
            status = .good
            reason = "No nicotine logged. Keeping it that way is among the best decisions you can make."
            currentDesc = "No nicotine logged"
        } else {
            status = .good
            reason = "No nicotine in the recent log window."
            currentDesc = "No recent use"
        }

        let frequency: ReminderFrequency = HealthThresholds.Reminders.nicotineDefault
        let nextDate = nextTrackingDate(from: lastEntry, frequency: frequency, status: status, now: now)
        let isStale = false
        let priorityScore = score(domain: .nicotine, status: status, trend: .unknown, isStableGoodLongTerm: false, isStale: isStale)

        return PriorityItem(
            domain: .nicotine,
            status: status,
            trend: .unknown,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.nicotine),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: "—",
            recommendedActions: RecommendationEngine.actions(for: .nicotine, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Dental

    private static func evaluateDental(_ entries: [ManualEntry], now: Date) -> PriorityItem {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let flossDays    = TrendAnalyzer.distinctDaysWithYes(entries, type: .dentalFloss, since: since, until: now)
        let fluorideDays = TrendAnalyzer.distinctDaysWithYes(entries, type: .dentalFluoride, since: since, until: now)
        let lastFloss    = TrendAnalyzer.mostRecent(entries, type: .dentalFloss)?.date
        let lastFluoride = TrendAnalyzer.mostRecent(entries, type: .dentalFluoride)?.date
        let lastEntry    = [lastFloss, lastFluoride].compactMap { $0 }.max()

        var status: DomainStatus
        var reason: String
        if lastEntry == nil {
            status = .missing
            reason = "Log floss/fluoride days when you do them."
        } else if flossDays >= HealthThresholds.Habit.goodDaysPerWeek {
            status = .good
            reason = "Flossing most days — keep going."
        } else if flossDays >= HealthThresholds.Habit.borderlineDaysPerWeek {
            status = .borderline
            reason = "A few floss days — try for daily."
        } else {
            status = .bad
            reason = "Flossing has been inconsistent."
        }

        let currentDesc = "Floss \(flossDays)/7d · Fluoride \(fluorideDays)/7d"
        let trend: TrendDirection = .unknown
        let trendDesc = "—"

        let frequency: ReminderFrequency = HealthThresholds.Reminders.dentalDefault
        let isStale = false  // dental almost never surfaces; don't artificially boost
        let nextDate = nextTrackingDate(from: lastEntry, frequency: frequency, status: status, now: now)
        let priorityScore = score(domain: .dental, status: status, trend: trend, isStableGoodLongTerm: false, isStale: isStale)

        return PriorityItem(
            domain: .dental,
            status: status,
            trend: trend,
            priorityScore: priorityScore,
            impactWeight: HealthThresholds.impactWeight(.dental),
            reason: reason,
            currentValueDescription: currentDesc,
            trendDescription: trendDesc,
            recommendedActions: RecommendationEngine.actions(for: .dental, status: status),
            nextTrackingDate: nextDate,
            reminderFrequency: frequency,
            dataIsStale: isStale
        )
    }

    // MARK: - Helpers

    private static func trendDescription(_ trend: TrendDirection, hasRecent: Bool, hasPrior: Bool) -> String {
        guard hasRecent else { return "No recent data" }
        guard hasPrior else  { return "Need more history" }
        switch trend {
        case .improving: return "Improving vs prior window"
        case .worsening: return "Worsening vs prior window"
        case .stable:    return "Stable vs prior window"
        case .unknown:   return "—"
        }
    }
}
