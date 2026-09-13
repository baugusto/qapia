import QapiaCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @State private var meetingPendingDeletion: Meeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandSignalMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("QAP.ia")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                    Text("Inteligência local")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 26)

            VStack(spacing: 4) {
                SidebarButton(
                    title: "Home",
                    systemImage: "house",
                    isSelected: [.empty, .recording, .paused, .processing].contains(viewModel.screen),
                    action: viewModel.showRecordings
                )

                SidebarButton(
                    title: "Configurações",
                    systemImage: "gearshape",
                    isSelected: viewModel.screen == .settings,
                    action: viewModel.showSettings
                )
                .help("Gerenciar templates de resumo")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Buscar reuniões", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Limpar busca")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(QapiaColors.surfaceHover.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 16)
            .help("Busque por reunião, participante, data, horário ou conteúdo")

            Text("RECENTES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.7)
                .padding(.top, 32)
                .padding(.horizontal, 9)
                .padding(.bottom, 7)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(viewModel.filteredMeetings) { meeting in
                        MeetingHistoryRow(
                            meeting: meeting,
                            isSelected: viewModel.selectedMeetingID == meeting.id,
                            deleteAction: viewModel.canDeleteMeeting(meeting) ? {
                                meetingPendingDeletion = meeting
                            } : nil
                        ) {
                            viewModel.selectMeeting(meeting)
                        }
                    }
                    if viewModel.filteredMeetings.isEmpty, !viewModel.searchText.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                            Text("Nenhuma reunião encontrada")
                                .multilineTextAlignment(.center)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 22)
                    }
                }
            }

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(QapiaColors.success)
                    Text("Privado e local")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(QapiaColors.surfaceHover.opacity(0.72))
                .clipShape(Capsule())

                Text("Versão \(appVersion)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 9)
            }
        }
        .padding(18)
        .frame(width: 242)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(QapiaColors.sidebar)
        .alert(
            "Excluir gravação?",
            isPresented: Binding(
                get: { meetingPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { meetingPendingDeletion = nil }
                }
            )
        ) {
            Button("Cancelar", role: .cancel) {
                meetingPendingDeletion = nil
            }
            Button("Excluir", role: .destructive) {
                guard let meeting = meetingPendingDeletion else { return }
                meetingPendingDeletion = nil
                viewModel.deleteMeeting(meeting)
            }
        } message: {
            Text("O áudio, a transcrição e o resumo serão removidos permanentemente deste Mac.")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
