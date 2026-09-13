import AppKit
import QapiaCore
import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @Binding var selectedTheme: QapiaTheme

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 242, ideal: 242, max: 242)
        } detail: {
            ContentView(viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .background(QapiaColors.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ThemeToggleButton(theme: selectedTheme) {
                    selectedTheme.toggle()
                }
            }
        }
        .alert(viewModel.errorTitle ?? "Não foi possível concluir a operação", isPresented: Binding(
            get: { viewModel.recordingError != nil },
            set: { isPresented in
                if !isPresented { viewModel.dismissRecordingError() }
            }
        )) {
            if viewModel.shouldOpenScreenRecordingSettings {
                Button("Abrir Ajustes") {
                    openScreenRecordingSettings()
                    viewModel.dismissRecordingError()
                }
            }
            Button("OK", role: .cancel) {
                viewModel.dismissRecordingError()
            }
        } message: {
            Text(viewModel.recordingError ?? "")
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSetupBannerVisible {
                LocalSetupBanner(viewModel: viewModel)
                    .padding(.horizontal, 36)
                    .padding(.top, 18)
            }

            ScrollView {
                Group {
                    switch viewModel.screen {
                    case .empty:
                        EmptyStateView(viewModel: viewModel)
                    case .settings:
                        SettingsView(viewModel: viewModel)
                    case .recording:
                        RecordingStateView(viewModel: viewModel)
                    case .paused:
                        PausedStateView(viewModel: viewModel)
                    case .processing:
                        ProcessingStateView(viewModel: viewModel)
                    case .meetingDetail:
                        MeetingDetailView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 36)
                .padding(.vertical, 32)
            }
        }
        .background {
            ZStack {
                QapiaColors.canvas
                RadialGradient(
                    colors: [QapiaColors.accent.opacity(0.075), .clear],
                    center: .topTrailing,
                    startRadius: 10,
                    endRadius: 440
                )
            }
            .ignoresSafeArea()
        }
    }
}

private struct LocalSetupBanner: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        HStack(spacing: 13) {
            BrandSignalMark(size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.applicationSetupPhase.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(viewModel.applicationSetupPhase.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if case .failed = viewModel.applicationSetupPhase {
                Button("Tentar novamente", action: viewModel.retryApplicationSetup)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if viewModel.applicationSetupPhase != .ready {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(QapiaColors.success)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(QapiaColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(QapiaColors.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
