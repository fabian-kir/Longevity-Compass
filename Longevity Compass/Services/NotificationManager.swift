import Foundation
import UserNotifications

@Observable
final class NotificationManager {

    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var lastError: String?

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "lc."

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

    private static let nutritionEntryTypes: Set<ManualEntryType> = [.proteinHabit, .fiberHabit, .omega3Habit]

    func scheduleReminders(
        for result: PriorityEngine.Result,
        manualEntries: [ManualEntry],
        now: Date = .now
    ) async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        cancelAll()

        await schedulePriorityDigests(for: result, now: now)
        await scheduleWeeklyReview(result: result)
        await scheduleNutritionReminders(entries: manualEntries, now: now)
    }

    // MARK: - Priority digests

    private func schedulePriorityDigests(for result: PriorityEngine.Result, now: Date) async {
        let cal = Calendar.current
        var byDay: [Date: [PriorityItem]] = [:]
        for item in result.topItems {
            guard item.reminderFrequency != .never else { continue }
            guard let next = item.nextTrackingDate else { continue }
            let day = cal.startOfDay(for: next)
            if day >= cal.startOfDay(for: now) {
                byDay[day, default: []].append(item)
            }
        }

        let sortedDays = byDay.keys.sorted().prefix(14)
        let iso = ISO8601DateFormatter()
        for day in sortedDays {
            let items = byDay[day] ?? []
            let content = UNMutableNotificationContent()
            content.title = items.count == 1 ? "Quick health check" : "Today's health check"
            content.body  = bodyText(items: items)
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "\(identifierPrefix)daily.\(iso.string(from: day))",
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

    // MARK: - Nutrition reminders (20:00 daily + conditional 23:00)

    private func scheduleNutritionReminders(entries: [ManualEntry], now: Date) async {
        let cal = Calendar.current
        let loggedDays: Set<Date> = Set(
            entries
                .filter { Self.nutritionEntryTypes.contains($0.entryType) }
                .map { cal.startOfDay(for: $0.date) }
        )
        let today = cal.startOfDay(for: now)
        let iso = ISO8601DateFormatter()

        for offset in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let dayKey = iso.string(from: day)

            // 20:00 every day (unconditional nudge)
            if let trigger = forwardTrigger(for: day, hour: 20, minute: 0, now: now) {
                let twenty = UNMutableNotificationContent()
                twenty.title = "Nutrition check"
                twenty.body  = "Quick tap: protein, fibre, and omega-3 today?"
                twenty.sound = .default
                let req = UNNotificationRequest(
                    identifier: "\(identifierPrefix)nutrition.20.\(dayKey)",
                    content: twenty,
                    trigger: trigger
                )
                try? await center.add(req)
            }

            // 23:00 only if nothing logged that day (always true for future days; recheck on every refresh)
            if !loggedDays.contains(day),
               let trigger = forwardTrigger(for: day, hour: 23, minute: 0, now: now) {
                let late = UNMutableNotificationContent()
                late.title = "Last call"
                late.body  = "Nothing logged today — five seconds: protein, fibre, omega-3?"
                late.sound = .default
                let req = UNNotificationRequest(
                    identifier: "\(identifierPrefix)nutrition.23.\(dayKey)",
                    content: late,
                    trigger: trigger
                )
                try? await center.add(req)
            }
        }
    }

    // MARK: - Helpers

    private func makeTrigger(for day: Date, hour: Int, minute: Int) -> UNCalendarNotificationTrigger {
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
        dc.hour = hour
        dc.minute = minute
        return UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)
    }

    /// Like makeTrigger but returns nil if the target wall-clock has already passed (avoids scheduling notifications in the past).
    private func forwardTrigger(for day: Date, hour: Int, minute: Int, now: Date) -> UNCalendarNotificationTrigger? {
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: day)
        dc.hour = hour
        dc.minute = minute
        guard let fireDate = Calendar.current.date(from: dc), fireDate > now else { return nil }
        return UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)
    }

    private func bodyText(items: [PriorityItem]) -> String {
        if items.count == 1, let item = items.first {
            return singleItemBody(item)
        }
        let labels = items.map { "• \($0.title)" }.joined(separator: "\n")
        return "A few items to look at today:\n\(labels)"
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
        }
    }

    private func weeklyReviewBody(result: PriorityEngine.Result) -> String {
        if let first = result.topItems.first {
            return "This week's focus: \(first.title). Open the app for details."
        }
        return "Open Longevity Compass for a quick review."
    }
}
