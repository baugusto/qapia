import Combine
import Foundation

@MainActor
public final class MeetingViewModel: ObservableObject {
    @Published public private(set) var screen: QapiaScreen = .empty
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var audioLevel: Float = 0
    @Published public private(set) var meetings: [Meeting]
    @Published public var searchText = ""
    @Published public private(set) var templates: [SummaryTemplate] = SummaryTemplate.allCases
    @Published public var selectedMeetingID: UUID?
    @Published public var selectedTemplate: SummaryTemplate = .general
    @Published public var customTemplateStructure = ""
    @Published public private(set) var editingTemplateID: String?
    @Published public var templateNameDraft = ""
    @Published public var templateInstructionsDraft = ""
    @Published public var templateSectionsDraft = ""
    @Published public private(set) var templateEditorMessage: String?
    @Published public private(set) var templateEditorSaved = false
    @Published public var detailTab: MeetingDetailTab = .summary
    @Published public private(set) var copyFeedback: CopyFeedback = .idle
    @Published public private(set) var recordingError: String?
    @Published public private(set) var errorTitle: String?
    @Published public private(set) var shouldOpenScreenRecordingSettings = false
    @Published public private(set) var googleAccount: GoogleCalendarAccount?
    @Published public private(set) var calendarEvents: [CalendarEvent] = []
    @Published public private(set) var calendarStatusMessage: String?
    @Published public private(set) var isCalendarLoading = false
    @Published public var meetingTitleDraft = ""
    @Published public var meetingParticipantsDraft = ""
    @Published public private(set) var meetingMetadataMessage: String?
    @Published public private(set) var applicationSetupPhase: ApplicationSetupPhase = .idle
    @Published public private(set) var isSetupBannerVisible = false
    @Published public private(set) var processingMeetingIDs: Set<UUID> = []

    private let clipboard: ClipboardService
    private let store: any MeetingStore
    private let templateStore: any SummaryTemplateStore
    private let recordingSession: RecordingSession
    private let transcriptionService: TranscriptionService
    private let summaryService: SummaryService
    private let calendarService: any GoogleCalendarServing
    private let reminderScheduler: any CalendarReminderScheduling
    private let meetingFileStore: any MeetingFileStore
    private let resourcePreparer: any LocalResourcePreparing
    private var elapsedTimerTask: Task<Void, Never>?
    private var elapsedTimerAnchor: Date?
    private var elapsedAtTimerStart: TimeInterval = 0
    private var pendingCalendarReminderEventID: String?
    private var applicationSetupObservation: AnyCancellable?
    private var setupTask: Task<Void, Never>?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        store: MeetingStore = MockMeetingStore(),
        templateStore: SummaryTemplateStore? = nil,
        clipboard: ClipboardService = PasteboardClipboardService(),
        recordingSession: RecordingSession? = nil,
        transcriptionService: TranscriptionService? = nil,
        summaryService: SummaryService? = nil,
        calendarService: GoogleCalendarServing? = nil,
        reminderScheduler: CalendarReminderScheduling? = nil,
        fileStore: MeetingFileStore? = nil,
        resourcePreparer: LocalResourcePreparing? = nil
    ) {
        let resolvedFileStore = fileStore ?? LocalMeetingFileStore()
        self.store = store
        self.templateStore = templateStore ?? LocalSummaryTemplateStore()
        self.clipboard = clipboard
        self.meetingFileStore = resolvedFileStore
        self.recordingSession = recordingSession ?? RecordingSession(
            captureService: ScreenCaptureAudioService(),
            fileStore: resolvedFileStore
        )
        self.transcriptionService = transcriptionService ?? TranscriptionService(
            whisperService: WhisperCppService(),
            fileStore: resolvedFileStore
        )
        self.summaryService = summaryService ?? SummaryService(
            provider: OnDeviceSummaryProvider(),
            fileStore: resolvedFileStore
        )
        self.calendarService = calendarService ?? GoogleCalendarService()
        self.reminderScheduler = reminderScheduler ?? CalendarReminderScheduler()
        self.resourcePreparer = resourcePreparer ?? LocalResourcePreparationCoordinator.shared
        self.googleAccount = nil
        do {
            self.meetings = try store.loadMeetings()
        } catch {
            self.meetings = []
            self.errorTitle = "Não foi possível carregar o histórico"
            self.recordingError = error.localizedDescription
        }
        do {
            self.templates = try self.templateStore.loadTemplates()
            self.selectedTemplate = self.templates.first(where: { $0.id == SummaryTemplate.general.id })
                ?? self.templates.first
                ?? .general
        } catch {
            self.templates = SummaryTemplate.allCases
            self.templateEditorMessage = error.localizedDescription
        }
        self.recordingSession.audioLevelHandler = { [weak self] sample in
            self?.audioLevel = sample.combined
        }
        self.applicationSetupObservation = ApplicationSetupStatus.shared.$phase
            .sink { [weak self] phase in self?.applicationSetupPhase = phase }
        Task { [weak self] in await self?.restoreGoogleCalendarAccount() }
    }

    public func startApplicationServices() {
        guard setupTask == nil else { return }
        isSetupBannerVisible = true
        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await resourcePreparer.prepare()
                resumePendingProcessing()
                try? await Task.sleep(for: .seconds(2))
                if applicationSetupPhase == .ready {
                    isSetupBannerVisible = false
                }
            } catch {
                isSetupBannerVisible = true
            }
            setupTask = nil
        }
    }

    public func retryApplicationSetup() {
        setupTask?.cancel()
        setupTask = nil
        startApplicationServices()
    }

    public var selectedMeeting: Meeting? {
        guard let selectedMeetingID else { return nil }
        return meetings.first { $0.id == selectedMeetingID }
    }

    public var currentMeeting: Meeting {
        selectedMeeting ?? meetings.first ?? Meeting(title: "Reunião sem título")
    }

    public var filteredMeetings: [Meeting] {
        let query = normalized(searchText)
        guard !query.isEmpty else { return meetings }
        return meetings.filter { normalized($0.searchableText).contains(query) }
    }

    public var suggestedCalendarEvent: CalendarEvent? {
        calendarEvents.first { $0.isRecordingSuggestion() }
    }

    public var nextCalendarEvent: CalendarEvent? {
        calendarEvents.first { $0.end > Date() }
    }

    public var isGoogleCalendarConfigured: Bool { calendarService.isConfigured }

    private func restoreGoogleCalendarAccount() async {
        guard let account = await calendarService.restoreAccount() else { return }
        googleAccount = account
        await refreshCalendar()
    }

    public var elapsedText: String {
        let totalSeconds = max(0, Int(elapsed))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    public var editingTemplate: SummaryTemplate? {
        guard let editingTemplateID else { return nil }
        return templates.first { $0.id == editingTemplateID }
    }

    public var canDeleteEditingTemplate: Bool {
        editingTemplate.map { !$0.isBuiltIn } ?? false
    }

    public func showRecordings() {
        screen = .empty
        selectedMeetingID = nil
        detailTab = .summary
    }

    public func connectGoogleCalendar() {
        Task { [weak self] in
            guard let self else { return }
            isCalendarLoading = true
            calendarStatusMessage = nil
            do {
                googleAccount = try await calendarService.connect()
                calendarStatusMessage = "Agenda conectada. As próximas reuniões já podem ser sugeridas."
                await refreshCalendar()
            } catch {
                calendarStatusMessage = error.localizedDescription
            }
            isCalendarLoading = false
        }
    }

    public func disconnectGoogleCalendar() {
        Task { [weak self] in
            guard let self else { return }
            await calendarService.disconnect()
            googleAccount = nil
            calendarEvents = []
            calendarStatusMessage = "Conta desconectada."
        }
    }

    public func refreshGoogleCalendar() {
        Task { [weak self] in await self?.refreshCalendar() }
    }

    public func refreshCalendar(now: Date = Date()) async {
        guard googleAccount != nil else { return }
        isCalendarLoading = true
        do {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: now)
            let endOfHorizon = calendar.date(byAdding: .day, value: 14, to: startOfToday)
                ?? now.addingTimeInterval(14 * 24 * 60 * 60)
            let events = try await calendarService.upcomingEvents(
                from: startOfToday,
                through: endOfHorizon
            )
            calendarEvents = events
            calendarStatusMessage = events.isEmpty
                ? "Agenda sincronizada. Nenhuma reunião encontrada nos próximos 14 dias."
                : "Agenda sincronizada agora."
            await reminderScheduler.scheduleReminders(for: events)
            startPendingCalendarReminderIfAvailable()
        } catch {
            calendarStatusMessage = error.localizedDescription
        }
        isCalendarLoading = false
    }

    public func showSettings() {
        guard screen != .recording && screen != .paused else { return }
        screen = .settings
        if editingTemplateID == nil {
            selectTemplateForEditing(selectedTemplate.id)
        }
    }

    public func selectTemplateForEditing(_ id: String) {
        guard let template = templates.first(where: { $0.id == id }) else { return }
        editingTemplateID = template.id
        templateNameDraft = template.displayName
        templateInstructionsDraft = template.instructions
        templateSectionsDraft = template.sections.joined(separator: "\n")
        templateEditorMessage = nil
        templateEditorSaved = false
    }

    public func beginCreatingTemplate() {
        editingTemplateID = nil
        templateNameDraft = ""
        templateInstructionsDraft = ""
        templateSectionsDraft = "Resumo executivo\nDecisões\nPróximos passos"
        templateEditorMessage = nil
        templateEditorSaved = false
    }

    public func saveTemplateDraft() {
        let existing = editingTemplate
        let candidate = SummaryTemplate(
            id: existing?.id ?? "user-\(UUID().uuidString.lowercased())",
            displayName: templateNameDraft,
            instructions: templateInstructionsDraft,
            sections: SummaryTemplate.parseSections(templateSectionsDraft),
            isBuiltIn: existing?.isBuiltIn ?? false
        )

        do {
            let validated = try candidate.validated()
            guard !templates.contains(where: {
                $0.id != validated.id &&
                $0.displayName.compare(validated.displayName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                templateEditorMessage = "Já existe um template com esse nome."
                templateEditorSaved = false
                return
            }

            var updated = templates
            if let index = updated.firstIndex(where: { $0.id == validated.id }) {
                updated[index] = validated
            } else {
                updated.append(validated)
            }
            try templateStore.saveTemplates(updated)
            templates = updated
            editingTemplateID = validated.id
            templateNameDraft = validated.displayName
            templateInstructionsDraft = validated.instructions
            templateSectionsDraft = validated.sections.joined(separator: "\n")
            if selectedTemplate.id == validated.id {
                selectedTemplate = validated
            }
            templateEditorMessage = "Template salvo localmente."
            templateEditorSaved = true
        } catch {
            templateEditorMessage = error.localizedDescription
            templateEditorSaved = false
        }
    }

    public func duplicateEditingTemplate() {
        guard let source = editingTemplate else { return }
        var suffix = 1
        var name = "\(source.displayName) — cópia"
        while templates.contains(where: {
            $0.displayName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            suffix += 1
            name = "\(source.displayName) — cópia \(suffix)"
        }

        let copy = SummaryTemplate(
            id: "user-\(UUID().uuidString.lowercased())",
            displayName: name,
            instructions: source.instructions,
            sections: source.sections
        )
        do {
            let updated = templates + [copy]
            try templateStore.saveTemplates(updated)
            templates = updated
            selectTemplateForEditing(copy.id)
            templateEditorMessage = "Cópia criada."
            templateEditorSaved = true
        } catch {
            templateEditorMessage = error.localizedDescription
            templateEditorSaved = false
        }
    }

    public func deleteEditingTemplate() {
        guard let template = editingTemplate, !template.isBuiltIn else { return }
        do {
            let updated = templates.filter { $0.id != template.id }
            try templateStore.saveTemplates(updated)
            templates = updated
            if selectedTemplate.id == template.id {
                selectedTemplate = updated.first(where: { $0.id == SummaryTemplate.general.id })
                    ?? updated.first
                    ?? .general
            }
            if let next = updated.first {
                selectTemplateForEditing(next.id)
                templateEditorMessage = "Template excluído."
                templateEditorSaved = true
            } else {
                beginCreatingTemplate()
            }
        } catch {
            templateEditorMessage = error.localizedDescription
            templateEditorSaved = false
        }
    }

    public func startRecording() {
        Task { [weak self] in
            await self?.beginRecording()
        }
    }

    public func beginRecording(calendarEvent: CalendarEvent? = nil) async {
        guard screen == .empty || screen == .meetingDetail else { return }

        elapsed = 0
        audioLevel = 0
        let meeting = Meeting(
            createdAt: Date(),
            title: calendarEvent?.title ?? "Reunião nova",
            state: .recording,
            templateId: selectedTemplate.id,
            customTemplateStructure: selectedTemplate.snapshotValue,
            participants: calendarEvent?.participantNames ?? [],
            calendarEventID: calendarEvent?.id,
            scheduledStart: calendarEvent?.start,
            scheduledEnd: calendarEvent?.end
        )
        meetings.insert(meeting, at: 0)
        selectedMeetingID = meeting.id
        recordingError = nil
        errorTitle = nil
        shouldOpenScreenRecordingSettings = false
        persistMeeting(at: 0)

        do {
            try await recordingSession.start(meetingID: meeting.id)
            screen = .recording
            startElapsedTimer()
        } catch {
            markRecordingFailed(meetingID: meeting.id, error: error)
        }
    }

    public func startRecording(for event: CalendarEvent) {
        Task { [weak self] in await self?.beginRecording(calendarEvent: event) }
    }

    public func handleCalendarReminder(eventID: String) {
        pendingCalendarReminderEventID = eventID
        startPendingCalendarReminderIfAvailable()
    }

    public func pauseRecording() {
        guard selectedMeetingID != nil else {
            guard screen == .recording else { return }
            screen = .paused
            return
        }
        Task { [weak self] in
            await self?.pauseActiveRecording()
        }
    }

    public func pauseActiveRecording() async {
        guard screen == .recording else { return }
        stopElapsedTimer()
        do {
            _ = try await recordingSession.pause()
            synchronizeActiveMeeting(with: .paused)
            audioLevel = 0
            screen = .paused
        } catch {
            markCurrentRecordingFailed(error)
        }
    }

    public func resumeRecording() {
        guard selectedMeetingID != nil else {
            guard screen == .paused else { return }
            screen = .recording
            return
        }
        Task { [weak self] in
            await self?.resumeActiveRecording()
        }
    }

    public func resumeActiveRecording() async {
        guard screen == .paused else { return }
        do {
            try await recordingSession.resume()
            audioLevel = 0
            updateSelectedMeetingState(.recording)
            screen = .recording
            startElapsedTimer()
        } catch {
            markCurrentRecordingFailed(error)
        }
    }

    public func finishRecording() {
        guard selectedMeetingID != nil else {
            finishMockRecording()
            return
        }
        Task { [weak self] in
            await self?.finishActiveRecording()
        }
    }

    public func finishActiveRecording() async {
        guard screen == .recording || screen == .paused,
              let meetingID = selectedMeetingID else { return }
        stopElapsedTimer()
        do {
            _ = try await recordingSession.finish()
            audioLevel = 0
            synchronizeActiveMeeting(with: .preparingAudio, finishedAt: Date())
            screen = .processing
            startTranscriptionPipeline(for: meetingID)
        } catch {
            markCurrentRecordingFailed(error)
        }
    }

    public func selectMeeting(_ meeting: Meeting) {
        selectedMeetingID = meeting.id
        selectedTemplate = templates.first(where: { $0.id == meeting.templateId })
            ?? SummaryTemplate(id: meeting.templateId)
            ?? .general
        customTemplateStructure = meeting.customTemplateStructure
        meetingTitleDraft = meeting.title
        meetingParticipantsDraft = meeting.participantsText
        meetingMetadataMessage = nil
        detailTab = .summary
        switch meeting.state {
        case .preparingAudio, .transcribing, .transcribed, .summarizing:
            screen = .processing
        default:
            screen = .meetingDetail
        }
    }

    public func canDeleteMeeting(_ meeting: Meeting) -> Bool {
        switch meeting.state {
        case .recording, .paused, .preparingAudio, .transcribing, .transcribed, .summarizing:
            return false
        case .idle, .completed, .failed:
            return true
        }
    }

    public func deleteMeeting(_ meeting: Meeting) {
        guard canDeleteMeeting(meeting) else { return }

        do {
            try store.delete(id: meeting.id)
            meetings.removeAll { $0.id == meeting.id }
            if selectedMeetingID == meeting.id {
                selectedMeetingID = nil
                meetingTitleDraft = ""
                meetingParticipantsDraft = ""
                meetingMetadataMessage = nil
                showRecordings()
            }

            do {
                try meetingFileStore.deleteMeeting(meetingID: meeting.id)
            } catch {
                errorTitle = "A gravação foi removida do histórico"
                recordingError = "Alguns arquivos locais não puderam ser excluídos: \(error.localizedDescription)"
            }
        } catch {
            errorTitle = "Não foi possível excluir a gravação"
            recordingError = error.localizedDescription
        }
    }

    public func saveMeetingMetadata() {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return }
        let cleanTitle = meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            meetingMetadataMessage = "Informe um nome para a reunião."
            return
        }
        meetings[index].title = String(cleanTitle.prefix(120))
        meetings[index].participants = Self.parseParticipants(meetingParticipantsDraft)
        meetingTitleDraft = meetings[index].title
        meetingParticipantsDraft = meetings[index].participantsText
        persistMeeting(at: index)
        meetingMetadataMessage = "Detalhes salvos localmente."
    }

    public func retrySummary() {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }),
              !meetings[index].transcript.isEmpty else { return }

        meetings[index].templateId = selectedTemplate.id
        meetings[index].customTemplateStructure = selectedTemplate.snapshotValue
        recordingError = nil
        errorTitle = nil
        persistMeeting(at: index)
        screen = .processing
        startSummaryPipeline(for: selectedMeetingID)
    }

    public func tick() {
        guard screen == .recording else { return }
        elapsed += 1
    }

    public func preview(_ screen: QapiaScreen) {
        switch screen {
        case .empty:
            showRecordings()
        case .settings:
            showSettings()
        case .recording:
            elapsed = 1_968
            selectedMeetingID = nil
            self.screen = .recording
        case .paused:
            elapsed = 1_968
            selectedMeetingID = nil
            self.screen = .paused
        case .processing:
            if selectedMeetingID == nil {
                let meeting = Meeting(
                    createdAt: Date(),
                    recordedDuration: 1_968,
                    title: "Reunião em processamento",
                    state: .preparingAudio
                )
                meetings.insert(meeting, at: 0)
                selectedMeetingID = meeting.id
            }
            self.screen = .processing
        case .meetingDetail:
            selectedMeetingID = meetings.first?.id
            self.screen = .meetingDetail
        }
    }

    public func copySummary() {
        clipboard.copy(MarkdownPlainTextFormatter.plainText(from: currentMeeting.summary))
        copyFeedback = .copied

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.copyFeedback = .idle
        }
    }

    public func dismissRecordingError() {
        recordingError = nil
        errorTitle = nil
        shouldOpenScreenRecordingSettings = false
    }

    private func finishMockRecording() {
        guard screen == .recording || screen == .paused else { return }
        stopElapsedTimer()
        let meeting = Meeting(
            createdAt: Date(),
            recordedDuration: elapsed,
            title: "Reunião nova",
            state: .preparingAudio,
            templateId: selectedTemplate.id,
            customTemplateStructure: selectedTemplate.snapshotValue
        )
        meetings.insert(meeting, at: 0)
        selectedMeetingID = meeting.id
        screen = .processing
    }

    private func startPendingCalendarReminderIfAvailable() {
        guard screen == .empty || screen == .meetingDetail,
              let eventID = pendingCalendarReminderEventID,
              let event = calendarEvents.first(where: { $0.id == eventID }) else { return }
        pendingCalendarReminderEventID = nil
        startRecording(for: event)
    }

    private func synchronizeActiveMeeting(with state: MeetingState, finishedAt: Date? = nil) {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return }
        let segments = recordingSession.segments
        meetings[index].recordingSegments = segments
        meetings[index].recordedDuration = segments.reduce(0) { $0 + $1.recordedDuration }
        meetings[index].state = state
        meetings[index].finishedAt = finishedAt
        elapsed = meetings[index].recordedDuration
        persistMeeting(at: index)
    }

    private func updateSelectedMeetingState(_ state: MeetingState) {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return }
        meetings[index].state = state
        persistMeeting(at: index)
    }

    private func markCurrentRecordingFailed(_ error: Error) {
        guard let selectedMeetingID else { return }
        markRecordingFailed(meetingID: selectedMeetingID, error: error)
    }

    private func markRecordingFailed(meetingID: UUID, error: Error) {
        stopElapsedTimer()
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].state = .failed
            persistMeeting(at: index)
        }
        audioLevel = 0
        errorTitle = screen == .empty
            ? "Não foi possível iniciar a gravação"
            : "Não foi possível gravar a reunião"
        shouldOpenScreenRecordingSettings = error as? RecordingError == .systemAudioPermissionDenied
        recordingError = error.localizedDescription
        screen = .empty
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedAtTimerStart = elapsed
        elapsedTimerAnchor = Date()
        elapsedTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                self.refreshElapsedFromTimer()
            }
        }
    }

    private func stopElapsedTimer() {
        refreshElapsedFromTimer()
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
        elapsedTimerAnchor = nil
    }

    private func refreshElapsedFromTimer() {
        guard let elapsedTimerAnchor else { return }
        elapsed = elapsedAtTimerStart + max(0, Date().timeIntervalSince(elapsedTimerAnchor))
    }

    private func startTranscriptionPipeline(for meetingID: UUID) {
        guard processingTasks[meetingID] == nil else { return }
        processingMeetingIDs.insert(meetingID)
        processingTasks[meetingID] = Task { [weak self] in
            guard let self else { return }
            await self.transcribeMeeting(meetingID)
            self.processingMeetingIDs.remove(meetingID)
            self.processingTasks[meetingID] = nil
        }
    }

    private func startSummaryPipeline(for meetingID: UUID) {
        guard processingTasks[meetingID] == nil else { return }
        processingMeetingIDs.insert(meetingID)
        processingTasks[meetingID] = Task { [weak self] in
            guard let self else { return }
            await self.summarizeMeeting(meetingID)
            self.processingMeetingIDs.remove(meetingID)
            self.processingTasks[meetingID] = nil
        }
    }

    private func resumePendingProcessing() {
        for meeting in meetings {
            switch meeting.state {
            case .preparingAudio, .transcribing:
                startTranscriptionPipeline(for: meeting.id)
            case .summarizing:
                if meeting.transcript.isEmpty {
                    startTranscriptionPipeline(for: meeting.id)
                } else {
                    startSummaryPipeline(for: meeting.id)
                }
            case .transcribed:
                if meeting.transcript.isEmpty {
                    startTranscriptionPipeline(for: meeting.id)
                } else {
                    startSummaryPipeline(for: meeting.id)
                }
            default:
                continue
            }
        }
    }

    private func transcribeMeeting(_ meetingID: UUID) async {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }

        meetings[index].state = .transcribing
        persistMeeting(at: index)
        do {
            let transcript = try await transcriptionService.transcribe(
                meetingID: meetingID,
                segments: meetings[index].recordingSegments
            )
            guard let completedIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            meetings[completedIndex].transcript = transcript
            meetings[completedIndex].state = .transcribed
            persistMeeting(at: completedIndex)
            await summarizeMeeting(meetingID)
        } catch {
            guard let failedIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            meetings[failedIndex].state = .failed
            persistMeeting(at: failedIndex)
            presentProcessingFailureIfVisible(
                meetingID: meetingID,
                title: "Não foi possível transcrever a reunião",
                message: error.localizedDescription,
                detailTab: .transcript
            )
        }
    }

    private func summarizeMeeting(_ meetingID: UUID) async {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }

        meetings[index].state = .summarizing
        persistMeeting(at: index)
        let meeting = meetings[index]
        let baseTemplate = templates.first(where: { $0.id == meeting.templateId })
            ?? SummaryTemplate(id: meeting.templateId)
            ?? .general
        let template = baseTemplate.applyingSnapshot(meeting.customTemplateStructure)

        do {
            let summary = try await summaryService.generateSummary(
                meetingID: meetingID,
                transcript: meeting.transcript,
                template: template
            )
            guard let completedIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            meetings[completedIndex].summary = summary
            meetings[completedIndex].state = .completed
            persistMeeting(at: completedIndex)
            if selectedMeetingID == meetingID, screen == .processing {
                detailTab = .summary
                screen = .meetingDetail
            }
        } catch {
            guard let failedIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            meetings[failedIndex].state = .failed
            persistMeeting(at: failedIndex)
            presentProcessingFailureIfVisible(
                meetingID: meetingID,
                title: "Não foi possível gerar o resumo",
                message: error.localizedDescription,
                detailTab: .transcript
            )
        }
    }

    private func presentProcessingFailureIfVisible(
        meetingID: UUID,
        title: String,
        message: String,
        detailTab: MeetingDetailTab
    ) {
        guard selectedMeetingID == meetingID, screen == .processing else { return }
        errorTitle = title
        recordingError = message
        self.detailTab = detailTab
        screen = .meetingDetail
    }

    private func persistMeeting(at index: Int) {
        guard meetings.indices.contains(index) else { return }
        do {
            try store.save(meetings[index])
        } catch {
            if recordingError == nil {
                errorTitle = "Não foi possível salvar a reunião"
                recordingError = error.localizedDescription
            }
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func parseParticipants(_ value: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n")
        var seen = Set<String>()
        return value.components(separatedBy: separators).compactMap { raw in
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let key = clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return clean
        }
    }
}
