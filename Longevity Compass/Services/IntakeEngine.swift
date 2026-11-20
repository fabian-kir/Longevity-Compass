import Foundation

struct NutrientAmounts: Equatable {
    var energyKcal = 0.0
    var protein = 0.0
    var carbs = 0.0
    var fat = 0.0
    var fiber = 0.0

    subscript(nutrient: IntakeNutrient) -> Double {
        switch nutrient {
        case .energy:  energyKcal
        case .protein: protein
        case .carbs:   carbs
        case .fat:     fat
        case .fiber:   fiber
        }
    }

    mutating func add(_ entry: NutritionEntry) {
        energyKcal += entry.caloriesKcal ?? 0
        protein += entry.proteinGrams ?? 0
        carbs += entry.carbsGrams ?? 0
        fat += entry.fatGrams ?? 0
        fiber += entry.fiberGrams ?? 0
    }
}

enum IntakeProgress: Equatable {
    /// Below a limit, or short of a minimum, by this amount.
    case remaining(Double)
    /// A minimum is met.
    case reached
    /// Past a limit by this amount.
    case over(Double)
}

struct IntakeSummary {
    struct Day: Identifiable, Equatable {
        let date: Date
        let energyKcal: Double
        let mealCount: Int
        let isToday: Bool
        /// Later days of a fixed block that has not ended yet.
        let isUpcoming: Bool

        var id: Date { date }
    }

    let window: IntakeWindow
    let targets: IntakeTargets
    /// Every day the budget covers, oldest first. Never empty: today is always included.
    let days: [Day]
    let totals: NutrientAmounts
    let today: NutrientAmounts
    let mealCount: Int
    /// Meals in the window with no calorie value, e.g. photos the AI could not estimate.
    let mealsWithoutEnergy: Int
    let includesPhotoEstimates: Bool
    /// True when the window starts before the first logged meal, so those days are left out.
    let startsAtFirstLog: Bool

    var budgetDays: Int { days.count }

    /// Today plus the upcoming days of a fixed block.
    var daysLeft: Int { days.filter { $0.isToday || $0.isUpcoming }.count }

    var loggedDays: Int { days.filter { $0.mealCount > 0 }.count }

    func budget(for nutrient: IntakeNutrient) -> Double? {
        targets.daily(nutrient).map { $0 * Double(budgetDays) }
    }

    func progress(for nutrient: IntakeNutrient) -> IntakeProgress? {
        guard let budget = budget(for: nutrient) else { return nil }
        let consumed = totals[nutrient]
        switch targets.kind(for: nutrient) {
        case .minimum:
            return consumed >= budget ? .reached : .remaining(budget - consumed)
        case .limit:
            return consumed > budget ? .over(consumed - budget) : .remaining(budget - consumed)
        }
    }

    /// What is left of the budget spread over today and the rest of the window.
    /// Nil unless more than one day is left and there is something left.
    func remainingPerDay(for nutrient: IntakeNutrient) -> Double? {
        guard daysLeft > 1, case .remaining(let left) = progress(for: nutrient) else { return nil }
        return left / Double(daysLeft)
    }
}

/// Adds up logged intake over the user's chosen window and compares it with
/// daily targets scaled to the window length.
enum IntakeEngine {

    static func summary(
        entries: [NutritionEntry],
        targets: IntakeTargets,
        window: IntakeWindow,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> IntakeSummary {
        let firstLog = entries.map(\.date).min()
        let bounds = bounds(for: window, now: now, firstLog: firstLog, calendar: calendar)
        let todayStart = calendar.startOfDay(for: now)

        let inWindow = entries.filter { $0.date >= bounds.start && $0.date < bounds.end }
        let byDay = Dictionary(grouping: inWindow) { calendar.startOfDay(for: $0.date) }

        var days: [IntakeSummary.Day] = []
        var day = bounds.start
        while day < bounds.end {
            let meals = byDay[day] ?? []
            days.append(IntakeSummary.Day(
                date: day,
                energyKcal: meals.compactMap(\.caloriesKcal).reduce(0, +),
                mealCount: meals.count,
                isToday: day == todayStart,
                isUpcoming: day > todayStart
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }

        var totals = NutrientAmounts()
        var today = NutrientAmounts()
        for entry in inWindow {
            totals.add(entry)
            if calendar.startOfDay(for: entry.date) == todayStart {
                today.add(entry)
            }
        }

        return IntakeSummary(
            window: window,
            targets: targets,
            days: days,
            totals: totals,
            today: today,
            mealCount: inWindow.count,
            mealsWithoutEnergy: inWindow.filter { $0.caloriesKcal == nil }.count,
            includesPhotoEstimates: inWindow.contains { $0.source == .photo && $0.caloriesKcal != nil },
            startsAtFirstLog: bounds.startsAtFirstLog
        )
    }

    /// Start of the first and end (exclusive) of the last day in the window.
    ///
    /// Days before the first logged meal are dropped. Otherwise a new user on a
    /// 3-day window would see two empty days counted as fasting and a triple budget.
    /// Empty days after the first log stay in: on a fasting day, 0 kcal is the truth.
    static func bounds(
        for window: IntakeWindow,
        now: Date,
        firstLog: Date?,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date, startsAtFirstLog: Bool) {
        let today = calendar.startOfDay(for: now)
        let length = window.effectiveLength

        let start: Date
        let end: Date
        switch window.mode {
        case .daily, .rolling:
            start = calendar.date(byAdding: .day, value: -(length - 1), to: today) ?? today
            end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        case .fixed:
            let anchor = calendar.startOfDay(for: window.anchor)
            let offset = calendar.dateComponents([.day], from: anchor, to: today).day ?? 0
            // Floor division, so days before the anchor fall into earlier blocks too.
            let block = offset >= 0 ? offset / length : -((-offset + length - 1) / length)
            start = calendar.date(byAdding: .day, value: block * length, to: anchor) ?? today
            end = calendar.date(byAdding: .day, value: length, to: start) ?? today
        }

        if let firstLog {
            let firstDay = min(calendar.startOfDay(for: firstLog), today)
            if firstDay > start {
                return (firstDay, end, true)
            }
        }
        return (start, end, false)
    }
}
