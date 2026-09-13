import AppKit
import QapiaCore
import SwiftUI

@MainActor
final class RecordingExperienceController: NSObject, NSWindowDelegate {
    private let presenceMonitor = MeetingPresenceMonitor()
    private weak var viewModel: MeetingViewModel?
    private weak var mainWindow: NSWindow?
    private var panel: NSPanel?
    private var activeMeetingID: UUID?
    private var windowObservers: [NSObjectProtocol] = []

    func update(screen: QapiaScreen, viewModel: MeetingViewModel) {
        self.viewModel = viewModel

        switch screen {
        case .recording, .paused:
            let isNewRecording = activeMeetingID != viewModel.selectedMeetingID || activeMeetingID == nil
            if isNewRecording {
                activeMeetingID = viewModel.selectedMeetingID
                attachMainWindowIfNeeded()
                showPanel()
                if let activeMeetingID {
                    presenceMonitor.start(viewModel: viewModel, meetingID: activeMeetingID)
                }
                mainWindow?.miniaturize(nil)
            } else if panel == nil {
                showPanel()
            }

        case .empty, .settings, .processing, .meetingDetail:
            guard activeMeetingID != nil || panel != nil else { return }
            activeMeetingID = nil
            presenceMonitor.stop()
            removeWindowObservers()
            hidePanel()
            restoreMainWindow()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let frame = panel?.frame else { return }
        UserDefaults.standard.set(frame.origin.x, forKey: "qapia.recordingOverlay.x")
        UserDefaults.standard.set(frame.origin.y, forKey: "qapia.recordingOverlay.y")
    }

    private func attachMainWindowIfNeeded() {
        let appWindow = NSApp.windows.first { window in
            window !== panel && window.title == "QAP.ia" && window.styleMask.contains(.titled)
        } ?? NSApp.keyWindow

        guard let appWindow, mainWindow !== appWindow else { return }
        removeWindowObservers()
        mainWindow = appWindow

        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: appWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showPanel() }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: appWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        })
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }

    private func showPanel() {
        guard let viewModel else { return }
        let overlayPanel = panel ?? makePanel(viewModel: viewModel)
        panel = overlayPanel
        restorePanelPosition(overlayPanel)
        overlayPanel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func restoreMainWindow() {
        guard let mainWindow else { return }
        if mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow.makeKeyAndOrderFront(nil)
    }

    private func makePanel(viewModel: MeetingViewModel) -> NSPanel {
        let overlayPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 252, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlayPanel.level = .statusBar
        overlayPanel.isOpaque = false
        overlayPanel.backgroundColor = .clear
        overlayPanel.hasShadow = true
        overlayPanel.hidesOnDeactivate = false
        overlayPanel.becomesKeyOnlyIfNeeded = true
        overlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlayPanel.isMovableByWindowBackground = true
        overlayPanel.delegate = self
        overlayPanel.contentView = NSHostingView(
            rootView: RecordingOverlayView(viewModel: viewModel) { [weak self] in
                self?.restoreMainWindow()
            }
        )
        return overlayPanel
    }

    private func restorePanelPosition(_ overlayPanel: NSPanel) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "qapia.recordingOverlay.x") != nil,
           defaults.object(forKey: "qapia.recordingOverlay.y") != nil {
            let origin = NSPoint(
                x: defaults.double(forKey: "qapia.recordingOverlay.x"),
                y: defaults.double(forKey: "qapia.recordingOverlay.y")
            )
            let candidate = NSRect(origin: origin, size: overlayPanel.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                overlayPanel.setFrameOrigin(origin)
                return
            }
        }

        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            overlayPanel.center()
            return
        }
        overlayPanel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - overlayPanel.frame.width - 24,
            y: visibleFrame.maxY - overlayPanel.frame.height - 24
        ))
    }
}

private struct RecordingOverlayView: View {
    @ObservedObject var viewModel: MeetingViewModel
    let restoreAction: () -> Void

    private var isRecording: Bool { viewModel.screen == .recording }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: restoreAction) {
                HStack(spacing: 9) {
                    BrandSignalMark(size: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isRecording ? QapiaColors.recording : QapiaColors.accent)
                                .frame(width: 7, height: 7)
                            Text(isRecording ? "Gravando" : "Pausado")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        WaveformView(
                            level: viewModel.audioLevel,
                            isActive: isRecording,
                            barCount: 8,
                            height: 18
                        )
                    }

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Abrir QAP.ia")
            .accessibilityLabel(isRecording ? "QAP.ia está gravando. Abrir aplicativo." : "Gravação pausada. Abrir QAP.ia.")

            Divider()
                .frame(height: 34)

            OverlayControlButton(
                systemImage: isRecording ? "pause.fill" : "play.fill",
                accessibilityTitle: isRecording ? "Pausar gravação" : "Continuar gravação",
                role: .neutral
            ) {
                if isRecording {
                    viewModel.pauseRecording()
                } else {
                    viewModel.resumeRecording()
                }
            }

            OverlayControlButton(
                systemImage: "stop.fill",
                accessibilityTitle: "Encerrar gravação",
                role: .stop
            ) {
                viewModel.finishRecording()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: 252, height: 76)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct OverlayControlButton: View {
    enum Role {
        case neutral
        case stop
    }

    let systemImage: String
    let accessibilityTitle: String
    let role: Role
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(role == .stop ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background(role == .stop ? QapiaColors.recording : Color.primary.opacity(0.1))
                .clipShape(Circle())
                .overlay {
                    if role == .neutral {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
    }
}
