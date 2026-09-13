import AppKit
import Combine
import QapiaCore
import UserNotifications

final class QapiaNotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor private weak var viewModel: MeetingViewModel?
    @MainActor private var pendingCalendarEventID: String?
    @MainActor private let recordingExperienceController = RecordingExperienceController()
    @MainActor private var screenObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    @MainActor
    func attach(viewModel: MeetingViewModel) {
        if self.viewModel !== viewModel {
            screenObservation = viewModel.$screen.sink { [weak self, weak viewModel] screen in
                Task { @MainActor in
                    guard let self, let viewModel else { return }
                    self.recordingExperienceController.update(screen: screen, viewModel: viewModel)
                }
            }
        }
        self.viewModel = viewModel
        recordingExperienceController.update(screen: viewModel.screen, viewModel: viewModel)
        if let pendingCalendarEventID {
            self.pendingCalendarEventID = nil
            viewModel.handleCalendarReminder(eventID: pendingCalendarEventID)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let acceptedActions = [
            CalendarReminderScheduler.startRecordingActionIdentifier,
            UNNotificationDefaultActionIdentifier
        ]
        guard acceptedActions.contains(response.actionIdentifier),
              let eventID = response.notification.request.content.userInfo["calendarEventID"] as? String else {
            completionHandler()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let viewModel = self.viewModel {
                viewModel.handleCalendarReminder(eventID: eventID)
            } else {
                self.pendingCalendarEventID = eventID
            }
        }
        completionHandler()
    }
}
