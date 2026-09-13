import Foundation
import UserNotifications

@MainActor
public protocol CalendarReminderScheduling: AnyObject {
    func scheduleReminders(for events: [CalendarEvent]) async
}

@MainActor
public final class CalendarReminderScheduler: CalendarReminderScheduling {
    nonisolated public static let categoryIdentifier = "QAPIA_CALENDAR_MEETING"
    nonisolated public static let startRecordingActionIdentifier = "QAPIA_START_RECORDING"

    public init() {}

    public func scheduleReminders(for events: [CalendarEvent]) async {
        let center = UNUserNotificationCenter.current()
        let authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard authorized else { return }

        let startAction = UNNotificationAction(
            identifier: Self.startRecordingActionIdentifier,
            title: "Iniciar gravação",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        let identifiers = events.map { "qapia-calendar-\($0.id)" }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        for event in events {
            let reminderDate = event.start.addingTimeInterval(-10 * 60)
            guard reminderDate.timeIntervalSinceNow > 1 else { continue }
            let content = Self.notificationContent(for: event)
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: reminderDate
            )
            let request = UNNotificationRequest(
                identifier: "qapia-calendar-\(event.id)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    static func notificationContent(for event: CalendarEvent) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Reunião em 10 minutos"
        content.body = "\(event.title) — use Iniciar gravação para abrir o QAP.ia."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = ["calendarEventID": event.id]
        return content
    }
}
