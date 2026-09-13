@preconcurrency import ScreenCaptureKit
import Foundation
import QapiaCore

@MainActor
final class MeetingPresenceMonitor {
    private var pollingTask: Task<Void, Never>?
    private var detectionState = MeetingEndDetectionState()

    func start(viewModel: MeetingViewModel) {
        stop()
        detectionState = MeetingEndDetectionState()

        pollingTask = Task { [weak self, weak viewModel] in
            while !Task.isCancelled {
                guard let self, let viewModel else { return }
                await self.inspectMeetingPresence(viewModel: viewModel)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        detectionState = MeetingEndDetectionState()
    }

    private func inspectMeetingPresence(viewModel: MeetingViewModel) async {
        guard viewModel.screen == .recording || viewModel.screen == .paused else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let hasMeetingWindow = content.windows.contains { window in
                SupportedMeetingWindowDetector.matches(
                    applicationName: window.owningApplication?.applicationName,
                    windowTitle: window.title
                )
            }
            let shouldFinish = detectionState.observe(
                hasMeetingWindow: hasMeetingWindow,
                audioLevel: viewModel.audioLevel
            )

            if shouldFinish {
                stop()
                viewModel.finishRecording()
            }
        } catch {
            // A captura continua normalmente. A detecção automática é um auxílio e
            // nunca deve interromper a gravação quando o macOS não expõe as janelas.
        }
    }
}
