import Foundation
import UserNotifications

@Observable
final class NotificationManager {

    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var lastError: String?

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "lc."

    private static let nutritionDomains: Set<HealthDomain> = [.protein, .fiber, .omega3]
    private static let habitNutritionTypes: Set<ManualEntryType> = [.proteinHabit, .fiberHabit, .omega3Habit]
    private static let scheduleHorizonDays = 3

    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorizationStatus = granted ? .authorized : .denied
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    func scheduleReminders(
        for result: PriorityEngine.Result,
        manualEntries: [ManualEntry],
        nutritionEntries: [NutritionEntry],
        now: Date = .now
    ) async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        cancelAll()

        await schedulePriorityReminders(for: result, now: now)
        await scheduleWeeklyReview(result: result)
        await scheduleNutritionReminders(
            result: result,
            manualEntries: manualEntries,
            nutritionEntries: nutritionEntries,
            now: now
        )
    }

    // MARK: - Priority reminders (one notification per item)

    private func schedulePriorityReminders(for result: PriorityEngine.Result, now: Date) async {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let horizon = cal.date(byAdding: .day, value: Self.scheduleHorizonDays, to: today) else { return }
        let iso = ISO8601DateFormatter()

        for item in result.topItems {
            guard item.reminderFrequency != .never else { continue }
            guard let next = item.nextTrackingDate else { continue }
            let day = cal.startOfDay(for: next)
            guard day >= today, day <= horizon else { continue }

            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body  = singleItemBody(item)
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "\(identifierPrefix)priority.\(item.domain.rawValue).\(iso.string(from: day))",
                content: content,
                trigger: makeTrigger(for: day, hour: 9, minute: 0)
            )
            try? await center.add(req)
        }
    }

    // MARK: - Weekly review

    private func scheduleWeeklyReview(result: PriorityEngine.Result) async {
        let content = UNMutableNotificationContent()
        content.title = "Weekly health review"
        content.body  = weeklyReviewBody(result: result)
        content.sound = .default

        var dc = DateComponents()
        dc.weekday = 1  // Sunday
        dc.hour    = 18
        dc.minute  = 0
        let req = UNNotificationRequest(
            identifier: "\(identifierPrefix)weekly-review",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        )
        try? await center.add(req)
    }

    // MARK: - Nutrition reminder (20:00, only when nutrition is off-track)

    private func scheduleNutritionReminders(
        result: PriorityEngine.Result,
        manualEntries: [ManualEntry],
        nutritionEntries: [NutritionEntry],
        now: Date
    ) async {
        let nutritionNeedsAttention = result.allItems.contains { item in
            Self.nutritionDomains.contains(item.domain) &&
            (item.status == .bad || item.status == .borderline || item.status == .missing)
        }
        guard nutritionNeedsAttention else { return }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let iso = ISO8601DateFormatter()

        var loggedDays: Set<Date> = []
        for entry in manualEntries where Self.habitNutritionTypes.contains(entry.entryType) {
            loggedDays.insert(cal.startOfDay(for: entry.date))
        }
        for entry in nutritionEntries {
            loggedDays.insert(cal.startOfDay(for: entry.date))
        }

        for offset in 0..<Self.scheduleHorizonDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            // Skip today if the user already logged nutrition today; future days can't be checked yet.
            if offset == 0, loggedDays.contains(day) { continue }
            guard let trigger = forwardTrigger(for: day, hour: 20, minute: 0, now: now) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Nutrition check"
            content.body  = "Quick tap: protein, fibre, and omega-3 today?"
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "\(identifierPrefix)nutrition.20.\(iso.string(from: day))",
                content: content,
                trigger: trigger
            )
            try? await center.add(req)
        }
    }

    // MARK: - Helpers

    private func makeTrigger(for day: Date, hour: Int, minute: Int) -> UNCalendarNotificationTrigger {
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
        dc.hour = hour
        dc.minute = minute
        return UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)
    }

    /// Like makeTrigger but returns nil if the target wall-clock has already passed.
    private func forwardTrigger(for day: Date, hour: Int, minute: Int, now: Date) -> UNCalendarNotificationTrigger? {
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
        dc.hour = hour
        dc.minute = minute
        guard let fireDate = Calendar.current.date(from: dc), fireDate > now else { return nil }
        return UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)
    }

    private func singleItemBody(_ item: PriorityItem) -> String {
        switch item.domain {
        case .bloodPressure:
            return "Blood pressure check is due. Log a reading in Apple Health when you have a minute."
        case .cardio:
            return "Cardio trend is drifting. Aim for 2–3 Zone 2 sessions this week."
        case .strength:
            return "No strength sessions logged this week. One full-body session helps."
        case .sleep:
            return "Sleep has been short lately. Tonight: protect bedtime."
        case .protein:
            return "Add protein to two meals today."
        case .fiber:
            return "Add fibre at one main meal today."
        case .omega3:
            return "Plan one fatty-fish meal this week."
        case .alcohol:
            return "Plan an alcohol-free day."
        case .nicotine:
            return "Check in on the nicotine plan."
        case .dental:
            return "Floss today."
        case .bodyComposition:
            return "Weight is trending. Log a fresh reading in Apple Health when convenient."
        case .bloodwork:
            return "Bloodwork is due. Book a panel and log the results in the Bloodwork tab."
        }
    }

    private func weeklyReviewBody(result: PriorityEngine.Result) -> String {
        if let first = result.topItems.first {
            return "This week's focus: \(first.title). Open the app for details."
        }
        return "Open Longevity Compass for a quick review."
    }
}
