import Foundation
import OSLog
import QapiaCore

@MainActor
final class MeetingPresenceMonitor {
    private static let logger = Logger(subsystem: "br.com.qapia.app", category: "MeetingEnd")
    private var pollingTask: Task<Void, Never>?
    private var detectionState = MeetingEndDetectionState()
    private var activeMeetingID: UUID?

    func start(viewModel: MeetingViewModel, meetingID: UUID) {
        stop()
        detectionState = MeetingEndDetectionState()
        activeMeetingID = meetingID

        pollingTask = Task { [weak self, weak viewModel] in
            while !Task.isCancelled {
                guard let self, let viewModel else { return }
                await self.inspectMeetingPresence(viewModel: viewModel)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        detectionState = MeetingEndDetectionState()
        activeMeetingID = nil
    }

    private func inspectMeetingPresence(viewModel: MeetingViewModel) async {
        guard viewModel.screen == .recording || viewModel.screen == .paused else { return }

        guard let activeMeetingID,
              let activeMeeting = viewModel.meetings.first(where: { $0.id == activeMeetingID }) else {
            Self.logger.error("Reunião ativa ausente durante monitoramento; encerramento automático ignorado")
            return
        }

        // Core Audio exposes whether conferencing/browser processes still own
        // an active audio stream. This detects a real call ending without
        // reading window titles or any screen content.
        let hasMeetingAudioProcess = SupportedMeetingAudioProcessDetector
            .hasActiveMeetingProcess()
        let shouldFinish = detectionState.observe(
            hasMeetingWindow: hasMeetingAudioProcess,
            audioLevel: viewModel.audioLevel,
            scheduledEnd: activeMeeting.scheduledEnd
        )

        if shouldFinish {
            Self.logger.notice(
                "Encerramento automático após fim confirmado: processo=\(hasMeetingAudioProcess), nível=\(viewModel.audioLevel, format: .fixed(precision: 3))"
            )
            stop()
            viewModel.finishRecording()
        }
    }
}
