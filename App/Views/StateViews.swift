import QapiaCore
import SwiftUI

struct EmptyStateView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(
                title: "Home",
                subtitle: "Capture conversas e transforme áudio em clareza."
            ) {
                StatusIndicator(title: "Pronto", color: QapiaColors.success)
            }

            if viewModel.googleAccount != nil {
                UpcomingAgendaView(viewModel: viewModel)
            }

            SurfaceCard {
                HStack(spacing: 34) {
                    SignalHero()
                        .frame(width: 190)

                    VStack(alignment: .leading, spacing: 16) {
                        Text(viewModel.meetings.isEmpty ? "Sua próxima reunião começa aqui" : "Pronto para uma nova conversa")
                            .font(.system(size: 21, weight: .semibold))
                            .tracking(-0.3)

                        Text("O QAP.ia grava, transcreve e organiza tudo no seu Mac — com privacidade desde o primeiro segundo.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)

                        TemplateConfigurationView(
                            templates: viewModel.templates,
                            selection: $viewModel.newMeetingTemplate
                        )

                        QapiaActionButton(
                            title: viewModel.isStartingRecording ? "Preparando áudio…" : "Nova gravação",
                            kind: .primary,
                            systemImage: "waveform"
                        ) {
                            viewModel.startRecording()
                        }
                        .disabled(viewModel.isStartingRecording)
                    }
                    .frame(maxWidth: 430, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 290)
            }

            PrivacyNote(text: "Áudio, transcrição e resumo permanecem neste Mac.")
        }
    }
}

private struct SignalHero: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(QapiaColors.accent.opacity(0.07))
                .frame(width: 176, height: 176)
            Circle()
                .stroke(QapiaColors.accent.opacity(0.12), lineWidth: 1)
                .frame(width: 142, height: 142)
            BrandSignalMark(size: 116)
                .shadow(color: QapiaColors.accent.opacity(0.24), radius: 24, y: 10)
        }
        .accessibilityHidden(true)
    }
}

struct RecordingStateView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: viewModel.currentMeeting.title, subtitle: "Captura local em andamento") {
                StatusIndicator(title: "Gravando", color: QapiaColors.recording, pulses: true)
            }

            AudioStage(
                elapsedText: viewModel.elapsedText,
                level: viewModel.audioLevel,
                isActive: true,
                message: viewModel.audioLevel > 0.08 ? "Sinal de áudio detectado" : "Aguardando sinal de áudio"
            ) {
                RecordingControlButton(
                    title: "Pausar",
                    systemImage: "pause.fill",
                    role: .neutral,
                    action: viewModel.pauseRecording
                )
                RecordingControlButton(
                    title: "Encerrar",
                    systemImage: "stop.fill",
                    role: .stop,
                    action: viewModel.finishRecording
                )
            }

            PrivacyNote(text: "Captura protegida • nenhum áudio é enviado para a nuvem")
        }
    }
}

struct PausedStateView: View {
    @ObservedObject var viewModel: MeetingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: viewModel.currentMeeting.title, subtitle: "Gravação pausada · captura em espera") {
                StatusIndicator(title: "Pausado", color: QapiaColors.paused)
            }

            AudioStage(
                elapsedText: viewModel.elapsedText,
                level: 0,
                isActive: false,
                message: "Captura pausada"
            ) {
                RecordingControlButton(
                    title: "Retomar",
                    systemImage: "play.fill",
                    role: .primary,
                    action: viewModel.resumeRecording
                )
                RecordingControlButton(
                    title: "Encerrar",
                    systemImage: "stop.fill",
                    role: .stop,
                    action: viewModel.finishRecording
                )
            }

            PrivacyNote(text: "O segmento anterior já está protegido no seu Mac")
        }
    }
}

private struct UpcomingAgendaView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())

    private let visibleDayCount = 14

    private var today: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var lastAvailableDate: Date {
        Calendar.current.date(byAdding: .day, value: visibleDayCount - 1, to: today) ?? today
    }

    private var events: [CalendarEvent] {
        CalendarAgenda.events(
            from: viewModel.calendarEvents,
            on: selectedDate,
            relativeTo: Date(),
            limit: 5
        )
    }

    private var isToday: Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: today)
    }

    private var dayTitle: String {
        if isToday { return "Hoje" }
        return selectedDate.formatted(
            .dateTime
                .weekday(.wide)
                .day()
                .month(.wide)
                .locale(Locale(identifier: "pt_BR"))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Próximas reuniões")
                        .font(.system(size: 16, weight: .semibold))
                    Text(isToday ? "As próximas 5 a partir de agora" : dayTitle.capitalized)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !isToday {
                    Button("Hoje") {
                        selectedDate = today
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QapiaColors.accent)
                }

                AgendaNavigationButton(
                    systemImage: "chevron.left",
                    label: "Dia anterior",
                    isEnabled: selectedDate > today
                ) {
                    moveDay(by: -1)
                }

                AgendaNavigationButton(
                    systemImage: "chevron.right",
                    label: "Próximo dia",
                    isEnabled: selectedDate < lastAvailableDate
                ) {
                    moveDay(by: 1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)

            Divider()

            if events.isEmpty {
                HStack(spacing: 11) {
                    Image(systemName: viewModel.isCalendarLoading ? "arrow.triangle.2.circlepath" : "calendar.badge.checkmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(QapiaColors.accent)
                    Text(viewModel.isCalendarLoading ? "Atualizando agenda…" : "Nenhuma reunião restante neste dia")
                        .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        AgendaEventRow(
                            event: event,
                            isSuggestedNow: event.isRecordingSuggestion(),
                            startAction: { viewModel.startRecording(for: event) }
                        )
                        if index < events.count - 1 {
                            Divider()
                                .padding(.leading, 110)
                        }
                    }
                }
            }
        }
        .background(QapiaColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(QapiaColors.divider.opacity(0.82), lineWidth: 1)
        }
        .onAppear {
            if selectedDate < today { selectedDate = today }
        }
    }

    private func moveDay(by value: Int) {
        guard let candidate = Calendar.current.date(byAdding: .day, value: value, to: selectedDate) else { return }
        selectedDate = min(max(candidate, today), lastAvailableDate)
    }
}

private struct AgendaNavigationButton: View {
    let systemImage: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(QapiaColors.surfaceHover)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct AgendaEventRow: View {
    let event: CalendarEvent
    let isSuggestedNow: Bool
    let startAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Text(event.end.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 66, alignment: .trailing)

            Capsule()
                .fill(isSuggestedNow ? QapiaColors.success : QapiaColors.accent)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if isSuggestedNow {
                        Text("Agora")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(QapiaColors.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(QapiaColors.success.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                Text(eventDetails)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            QapiaActionButton(
                title: "Gravar",
                kind: isSuggestedNow ? .primary : .secondary,
                systemImage: "waveform",
                action: startAction
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var eventDetails: String {
        var details = event.participantNames.prefix(3).joined(separator: ", ")
        if details.isEmpty { details = event.location ?? "Google Calendar" }
        return details
    }
}

private struct AudioStage<Controls: View>: View {
    let elapsedText: String
    let level: Float
    let isActive: Bool
    let message: String
    private let controls: Controls

    init(
        elapsedText: String,
        level: Float,
        isActive: Bool,
        message: String,
        @ViewBuilder controls: () -> Controls
    ) {
        self.elapsedText = elapsedText
        self.level = level
        self.isActive = isActive
        self.message = message
        self.controls = controls()
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                AudioSourceBadge(title: "Sistema", systemImage: "speaker.wave.2.fill")
                AudioSourceBadge(title: "Microfone", systemImage: "mic.fill")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("Local")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(QapiaColors.audioStageMuted)
            }

            VStack(spacing: 5) {
                Text(elapsedText)
                    .font(.system(size: 47, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(QapiaColors.audioStageText)
                    .tracking(-1)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(QapiaColors.audioStageMuted)
            }

            WaveformView(level: level, isActive: isActive)

            HStack(spacing: 26) {
                controls
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 360)
        .background {
            ZStack {
                QapiaColors.audioStage
                RadialGradient(
                    colors: [QapiaColors.accent.opacity(isActive ? 0.19 : 0.08), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 380
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(QapiaColors.audioStageBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 22, y: 12)
    }
}

private struct AudioSourceBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(QapiaColors.audioStageMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(QapiaColors.audioStageBadge)
            .clipShape(Capsule())
    }
}

struct ProcessingStateView: View {
    @ObservedObject var viewModel: MeetingViewModel

    private var isSummarizing: Bool {
        viewModel.isCurrentMeetingSummarizing
    }

    private var processingTitle: String {
        isSummarizing ? "Estruturando o resumo local" : "Convertendo áudio em texto"
    }

    private var processingDescription: String {
        isSummarizing
            ? "O QAP.ia organiza a transcrição no próprio Mac, sem enviar a reunião para serviços externos."
            : "O áudio já está seguro. A transcrição será criada sem enviar a conversa para fora deste Mac."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Organizando a reunião", subtitle: "Processamento privado e local") {
                StatusIndicator(title: "Em andamento", color: QapiaColors.accent, pulses: true)
            }

            SurfaceCard {
                HStack(alignment: .top, spacing: 24) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(QapiaColors.accent.opacity(0.1))
                            .frame(width: 66, height: 66)
                        BrandSignalMark(size: 42)
                    }

                    VStack(alignment: .leading, spacing: 15) {
                        Text(processingTitle)
                            .font(.system(size: 18, weight: .semibold))

                        Text(processingDescription)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)

                        ProcessingActivityBar()

                        Divider()

                        VStack(spacing: 11) {
                            ProcessingStepRow(title: "Áudio local", state: "Concluído", color: QapiaColors.success, isComplete: true)
                            ProcessingStepRow(
                                title: "Transcrição",
                                state: isSummarizing ? "Concluída" : "Em andamento",
                                color: isSummarizing ? QapiaColors.success : QapiaColors.accent,
                                isComplete: isSummarizing
                            )
                            ProcessingStepRow(
                                title: "Resumo",
                                state: isSummarizing ? "Em andamento" : "A seguir",
                                color: isSummarizing ? QapiaColors.accent : .secondary,
                                isComplete: false
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 250)
            }

            PrivacyNote(text: "Você pode continuar usando o Mac enquanto o QAP.ia organiza a reunião")
        }
    }
}

struct MeetingDetailView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @State private var isEditingMetadata = false

    private var meeting: Meeting { viewModel.currentMeeting }

    private var availableTemplates: [SummaryTemplate] {
        var options = viewModel.templates
        if let index = options.firstIndex(where: { $0.id == viewModel.selectedTemplate.id }) {
            if selectedTemplateIsHistorical {
                options[index] = viewModel.selectedTemplate
            }
            return options
        }
        return [viewModel.selectedTemplate] + options
    }

    private var selectedTemplateIsHistorical: Bool {
        guard let current = viewModel.templates.first(where: {
            $0.id == viewModel.selectedTemplate.id
        }) else {
            return true
        }
        return current.displayName != viewModel.selectedTemplate.displayName ||
            current.instructions != viewModel.selectedTemplate.instructions ||
            current.sections != viewModel.selectedTemplate.sections ||
            current.isBuiltIn != viewModel.selectedTemplate.isBuiltIn
    }

    private var status: (title: String, color: Color) {
        switch meeting.state {
        case .transcribed: ("Transcrição pronta", QapiaColors.accent)
        case .failed: ("Ação necessária", QapiaColors.recording)
        default: ("Concluído", QapiaColors.success)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: meeting.title, subtitle: "Gravada em \(meeting.recordingMetadataText)") {
                HStack(spacing: 9) {
                    QapiaActionButton(
                        title: "Editar detalhes",
                        kind: .secondary,
                        systemImage: "pencil"
                    ) {
                        viewModel.meetingTitleDraft = meeting.title
                        viewModel.meetingParticipantsDraft = meeting.participantsText
                        isEditingMetadata.toggle()
                    }
                    StatusIndicator(title: status.title, color: status.color)
                }
            }

            if isEditingMetadata {
                MeetingMetadataEditor(viewModel: viewModel) {
                    viewModel.saveMeetingMetadata()
                    if viewModel.meetingMetadataMessage == "Detalhes salvos localmente." {
                        isEditingMetadata = false
                    }
                }
            } else if !meeting.participants.isEmpty || meeting.scheduledStart != nil {
                MeetingMetadataSummary(meeting: meeting)
            }

            HStack(spacing: 12) {
                Picker("Conteúdo", selection: $viewModel.detailTab) {
                    ForEach(MeetingDetailTab.allCases) { tab in
                        Text(tab.displayName).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Spacer()

                TemplateConfigurationView(
                    templates: availableTemplates,
                    selection: Binding(
                        get: { viewModel.selectedTemplate },
                        set: { template in
                            viewModel.selectSummaryTemplate(template)
                        }
                    )
                )

                Button(action: viewModel.retrySummary) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QapiaColors.accent)
                        .frame(width: 36, height: 36)
                        .background(QapiaColors.surfaceHover)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(QapiaColors.divider.opacity(0.9), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(meeting.transcript.isEmpty || viewModel.isCurrentMeetingSummarizing)
                .opacity(meeting.transcript.isEmpty || viewModel.isCurrentMeetingSummarizing ? 0.45 : 1)
                .help("Regenerar o resumo com o template selecionado")
                .accessibilityLabel("Regenerar resumo")

                if selectedTemplateIsHistorical {
                    Label("Histórico", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("Esta reunião preserva a versão do template usada quando foi gravada.")
                }
            }

            if meeting.hasUnavailableAudio {
                Label(
                    meeting.missingRecordingSegmentCount == 1
                        ? "Um arquivo de áudio não está disponível; os demais dados foram preservados."
                        : "\(meeting.missingRecordingSegmentCount) arquivos de áudio não estão disponíveis; os demais dados foram preservados.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(QapiaColors.paused)
            }

            if !meeting.captureWarnings.isEmpty {
                Label(
                    meeting.captureWarnings.joined(separator: " "),
                    systemImage: "waveform.badge.exclamationmark"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(QapiaColors.paused)
                .textSelection(.enabled)
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label(
                            viewModel.detailTab == .summary ? "Resumo da reunião" : "Transcrição completa",
                            systemImage: viewModel.detailTab == .summary ? "sparkles" : "text.alignleft"
                        )
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        Spacer()

                        if !meeting.summary.isEmpty, viewModel.detailTab == .summary {
                            QapiaActionButton(
                                title: viewModel.copyFeedback == .copied ? "Copiado" : "Copiar",
                                kind: .secondary,
                                systemImage: viewModel.copyFeedback == .copied ? "checkmark" : "doc.on.doc",
                                action: viewModel.copySummary
                            )
                        }
                    }

                    Divider()

                    if viewModel.detailTab == .summary, !meeting.summary.isEmpty {
                        EditableSummaryView(viewModel: viewModel)
                    } else {
                        ScrollView {
                            Text(contentText)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(minHeight: 190, idealHeight: 440, maxHeight: 540)
                        .scrollBounceBehavior(.basedOnSize)
                    }

                    if (viewModel.detailTab == .transcript && !meeting.recordingSegments.isEmpty)
                        || (viewModel.detailTab == .summary && !meeting.transcript.isEmpty) {
                        Divider()
                        HStack {
                            Spacer()
                            if viewModel.detailTab == .transcript {
                                QapiaActionButton(
                                    title: meeting.transcript.isEmpty
                                        ? "Gerar transcrição"
                                        : "Transcrever novamente",
                                    kind: .secondary,
                                    systemImage: "waveform",
                                    action: viewModel.retryTranscription
                                )
                            } else if meeting.summary.isEmpty || meeting.state == .failed {
                                QapiaActionButton(
                                    title: "Tentar gerar resumo",
                                    kind: .primary,
                                    systemImage: "sparkles",
                                    action: viewModel.retrySummary
                                )
                            }
                        }
                    }
                }
            }

            PrivacyNote(text: "Resumo e transcrição gerados localmente no seu Mac")
        }
    }

    private var contentText: String {
        if viewModel.detailTab == .summary {
            return meeting.summary.isEmpty ? "O resumo ainda não está disponível." : meeting.summary
        }
        return meeting.transcript.isEmpty ? "A transcrição ainda não está disponível." : meeting.transcript
    }
}

private struct EditableSummaryView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @State private var isEditing = false
    @StateObject private var richTextController = SummaryRichTextController()
    @State private var richTextHeight: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                SummaryFormattingToolbar(controller: richTextController) {
                    isEditing = false
                }
                GeometryReader { geometry in
                    RichTextSummaryEditor(
                        markdown: Binding(
                            get: { viewModel.summaryDraft },
                            set: { newValue in viewModel.updateSummary(newValue) }
                        ),
                        controller: richTextController,
                        onFocusChange: { focused in
                            guard !focused else { return }
                            DispatchQueue.main.async { isEditing = false }
                        },
                        layoutWidth: geometry.size.width,
                        contentHeight: $richTextHeight
                    )
                    .frame(width: geometry.size.width, height: richTextHeight)
                }
                .frame(height: richTextHeight)
            } else {
                MarkdownSummaryView(markdown: viewModel.summaryDraft)
                    .contentShape(Rectangle())
                    .onTapGesture { isEditing = true }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Clique para editar. As alterações são salvas automaticamente.")
            }

            HStack(spacing: 6) {
                Image(systemName: viewModel.summaryAutosaveMessage == "Salvando…" ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                Text(viewModel.summaryAutosaveMessage ?? "Clique no texto para editar · salvamento automático")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}

private struct SummaryFormattingToolbar: View {
    let controller: SummaryRichTextController
    let finish: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Menu {
                Button("Texto normal", action: controller.setParagraphStyle)
                Button("Título", action: controller.setHeadingStyle)
            } label: {
                Label("Estilo", systemImage: "textformat.size")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 18)
            formattingButton("Negrito", systemImage: "bold", action: controller.toggleBold)
            formattingButton("Itálico", systemImage: "italic", action: controller.toggleItalic)
            formattingButton("Lista com marcadores", systemImage: "list.bullet", action: controller.toggleBulletedList)
            formattingButton("Lista numerada", systemImage: "list.number", action: controller.toggleNumberedList)

            Spacer()

            Button("Concluir", action: finish)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(QapiaColors.accent)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(QapiaColors.surfaceHover)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func formattingButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct MeetingMetadataEditor: View {
    @ObservedObject var viewModel: MeetingViewModel
    let saveAction: () -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Detalhes da reunião", systemImage: "person.2")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    QapiaActionButton(
                        title: "Salvar",
                        kind: .primary,
                        systemImage: "checkmark",
                        action: saveAction
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Nome da reunião")
                        .font(.system(size: 11, weight: .medium))
                    TextField("Nome da reunião", text: $viewModel.meetingTitleDraft)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background(QapiaColors.surfaceHover)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Participantes")
                        .font(.system(size: 11, weight: .medium))
                    TextField("Nomes ou e-mails, separados por vírgula", text: $viewModel.meetingParticipantsDraft)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background(QapiaColors.surfaceHover)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                if let message = viewModel.meetingMetadataMessage {
                    Text(message)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(message.hasPrefix("Detalhes") ? QapiaColors.success : QapiaColors.recording)
                }
            }
        }
    }
}

private struct MeetingMetadataSummary: View {
    let meeting: Meeting
    @State private var showsAllParticipants = false

    private let participantColumns = [
        GridItem(.flexible(), spacing: 12, alignment: .leading),
        GridItem(.flexible(), spacing: 12, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                if let scheduledStart = meeting.scheduledStart {
                    Label(
                        scheduledStart.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "calendar"
                    )
                }
                if !meeting.participants.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsAllParticipants.toggle()
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "person.2")
                            Text(meeting.participantPreview())
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(showsAllParticipants ? 180 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showsAllParticipants ? "Ocultar participantes" : "Exibir todos os participantes")
                    .accessibilityLabel(showsAllParticipants ? "Ocultar participantes" : "Exibir todos os participantes")
                }
            }

            if showsAllParticipants, !meeting.participants.isEmpty {
                LazyVGrid(columns: participantColumns, alignment: .leading, spacing: 8) {
                    ForEach(Array(meeting.participants.enumerated()), id: \.offset) { _, participant in
                        Label(participant, systemImage: "person.crop.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(participant)
                    }
                }
                .padding(12)
                .background(QapiaColors.surfaceHover.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(QapiaColors.divider.opacity(0.8), lineWidth: 1)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

}

struct PrivacyNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}
