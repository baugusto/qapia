@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
private final class RecordingFinalizationBarrier {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func complete(with result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume(returning: result) }
    }
}

@MainActor
public final class MeetingViewModel: ObservableObject {
    @Published public private(set) var screen: QapiaScreen = .empty
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var audioLevel: Float = 0
    @Published public private(set) var meetings: [Meeting]
    @Published public var searchText = ""
    @Published public private(set) var templates: [SummaryTemplate] = SummaryTemplate.allCases
    @Published public var selectedMeetingID: UUID?
    @Published public var newMeetingTemplate: SummaryTemplate = .standardMeeting
    @Published public var selectedTemplate: SummaryTemplate = .standardMeeting
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
    @Published public private(set) var shouldOpenSystemAudioSettings = false
    @Published public private(set) var googleAccount: GoogleCalendarAccount?
    @Published public private(set) var calendarEvents: [CalendarEvent] = []
    @Published public private(set) var calendarStatusMessage: String?
    @Published public private(set) var isCalendarLoading = false
    @Published public var meetingTitleDraft = ""
    @Published public var meetingParticipantsDraft = ""
    @Published public private(set) var meetingMetadataMessage: String?
    @Published public private(set) var summaryDraft = ""
    @Published public private(set) var summaryAutosaveMessage: String?
    @Published public private(set) var applicationSetupPhase: ApplicationSetupPhase = .idle
    @Published public private(set) var prerequisiteItems: [LocalPrerequisiteItem] = []
    @Published public private(set) var selectedOllamaModel: OllamaModelChoice = .fourB
    @Published public private(set) var isSetupBannerVisible = false
    @Published public private(set) var isStartingRecording = false
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
    private var prerequisiteObservation: AnyCancellable?
    private var setupTask: Task<Void, Never>?
    private var setupGeneration: UInt64 = 0
    private var hasScheduledColdLaunchRecovery = false
    private var coldLaunchRecoveryMeetingIDs: Set<UUID>?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var summaryGenerations: [UUID: UInt64] = [:]
    private var audioFinalizationBarriers: [UUID: RecordingFinalizationBarrier] = [:]
    private var terminationPreparationBarrier: RecordingFinalizationBarrier?
    private var unpersistedCriticalMeetingIDs: Set<UUID> = []
    private var deferredProcessingMeetingIDs: Set<UUID> = []
    private var isRecordingTransitionInProgress = false
    private var pendingFinishMeetingID: UUID?
    private var isPreparingForTermination = false
    private var pauseCheckpointBlockedMeetingID: UUID?
    private var startingMeetingID: UUID?
    private var interruptedAudioDurationValidator:
        (@MainActor (URL) async -> TimeInterval?)?
    private var interruptedAudioCombiner:
        (@MainActor (
            URL,
            URL,
            URL,
            TimeInterval,
            TimeInterval,
            Bool,
            Bool
        ) async throws -> URL)?

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
            captureService: CoreAudioTapCaptureService(),
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
        self.selectedOllamaModel = OllamaModelPreference.selectedChoice()
        self.googleAccount = nil
        do {
            self.meetings = try store.loadMeetings()
        } catch {
            self.meetings = []
            self.errorTitle = "Não foi possível carregar o histórico"
            self.recordingError = error.localizedDescription
        }
        self.summaryDraft = self.meetings.first?.summary ?? ""
        do {
            self.templates = try self.templateStore.loadTemplates()
            let standardTemplate = self.templates.first(where: { $0.id == SummaryTemplate.standardMeeting.id })
                ?? self.templates.first
                ?? .standardMeeting
            self.newMeetingTemplate = standardTemplate
            self.selectedTemplate = standardTemplate
        } catch {
            self.templates = SummaryTemplate.allCases
            self.templateEditorMessage = error.localizedDescription
        }
        self.recordingSession.audioLevelHandler = { [weak self] sample in
            self?.audioLevel = sample.combined
        }
        self.applicationSetupObservation = ApplicationSetupStatus.shared.$phase
            .sink { [weak self] phase in self?.applicationSetupPhase = phase }
        self.prerequisiteItems = ApplicationPrerequisiteStatus.shared.items
        self.prerequisiteObservation = ApplicationPrerequisiteStatus.shared.$items
            .sink { [weak self] items in self?.prerequisiteItems = items }
        Task { [weak self] in await self?.restoreGoogleCalendarAccount() }
    }

    func configureInterruptedRecordingRecoveryForTesting(
        validAudioDuration: @escaping @MainActor (URL) async -> TimeInterval?,
        combineAudioTracks: @escaping @MainActor (
            URL,
            URL,
            URL,
            TimeInterval,
            TimeInterval,
            Bool,
            Bool
        ) async throws -> URL
    ) {
        interruptedAudioDurationValidator = validAudioDuration
        interruptedAudioCombiner = combineAudioTracks
    }

    public func startApplicationServices() {
        guard setupTask == nil else { return }
        launchApplicationSetup(
            after: nil,
            recoverInterruptedMeetingIDs: claimColdLaunchRecoveryMeetingIDs()
        )
    }

    public func retryApplicationSetup() {
        guard setupTask == nil else { return }
        // Recovery is a cold-launch migration over an immutable allowlist. A
        // resource/model retry must never rescan meetings created by this live
        // process because one of them may own open Core Audio files.
        launchApplicationSetup(after: nil, recoverInterruptedMeetingIDs: nil)
    }

    public func refreshPrerequisiteDiagnostics() {
        ApplicationPrerequisiteStatus.shared.refreshEnvironmentChecks()
        retryApplicationSetup()
    }

    public func selectOllamaModel(_ choice: OllamaModelChoice) {
        guard choice != selectedOllamaModel else { return }
        selectedOllamaModel = choice
        OllamaModelPreference.select(choice)

        // A model change must not race an installation already in progress.
        // Cancel the UI generation and queue the new check after the previous
        // preparation task has released its download/process resources.
        let previousTask = setupTask
        previousTask?.cancel()
        setupTask = nil
        launchApplicationSetup(after: previousTask, recoverInterruptedMeetingIDs: nil)
    }

    private func launchApplicationSetup(
        after previousTask: Task<Void, Never>?,
        recoverInterruptedMeetingIDs: Set<UUID>?
    ) {
        setupGeneration &+= 1
        let generation = setupGeneration
        isSetupBannerVisible = true
        setupTask = Task { [weak self] in
            if let previousTask {
                // A retry never overlaps the recovery/export owned by the
                // previous generation. This remains single-flight even when
                // the suspended operation itself ignores cancellation.
                await previousTask.value
            }
            guard let self,
                  !Task.isCancelled,
                  setupGeneration == generation else { return }
            defer {
                if setupGeneration == generation {
                    setupTask = nil
                }
            }
            // Salvage only the immutable rows observed at cold launch. Model
            // validation or a first-run download must never prevent recovery,
            // while retries must never reinterpret a live recording as stale.
            if let recoverInterruptedMeetingIDs, !recoverInterruptedMeetingIDs.isEmpty {
                coldLaunchRecoveryMeetingIDs = recoverInterruptedMeetingIDs
                await recoverInterruptedRecordings()
                coldLaunchRecoveryMeetingIDs = nil
            }
            guard !Task.isCancelled, setupGeneration == generation else { return }
            do {
                try await resourcePreparer.prepare()
                guard !Task.isCancelled, setupGeneration == generation else { return }
                resumePendingProcessing()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled, setupGeneration == generation else { return }
                if applicationSetupPhase == .ready {
                    isSetupBannerVisible = false
                }
            } catch {
                if !Task.isCancelled, setupGeneration == generation {
                    isSetupBannerVisible = true
                }
            }
        }
    }

    private func claimColdLaunchRecoveryMeetingIDs() -> Set<UUID>? {
        guard !hasScheduledColdLaunchRecovery else { return nil }
        hasScheduledColdLaunchRecovery = true
        let protectedMeetingIDs = interruptedRecoveryProtectedMeetingIDs
        return Set(meetings.compactMap { meeting in
            guard !protectedMeetingIDs.contains(meeting.id),
                  meeting.state == .recording
                    || meeting.state == .paused
                    || (meeting.state == .preparingAudio && meeting.transcript.isEmpty)
                    || (meeting.state == .idle && meeting.recordingSegments.isEmpty)
                    || (meeting.state == .failed && meeting.transcript.isEmpty) else {
                return nil
            }
            return meeting.id
        })
    }

    private var interruptedRecoveryProtectedMeetingIDs: Set<UUID> {
        var protectedMeetingIDs = Set(audioFinalizationBarriers.keys)
        if let startingMeetingID {
            protectedMeetingIDs.insert(startingMeetingID)
        }
        if (isStartingRecording
            || isRecordingTransitionInProgress
            || screen == .recording
            || screen == .paused),
           let selectedMeetingID {
            protectedMeetingIDs.insert(selectedMeetingID)
        }
        return protectedMeetingIDs
    }

    public var selectedMeeting: Meeting? {
        guard let selectedMeetingID else { return nil }
        return meetings.first { $0.id == selectedMeetingID }
    }

    public var currentMeeting: Meeting {
        selectedMeeting ?? meetings.first ?? Meeting(title: "Reunião sem título")
    }

    public var isCurrentMeetingSummarizing: Bool {
        switch currentMeeting.state {
        case .preparingAudio, .transcribing:
            return false
        case .summarizing:
            return true
        default:
            return screen == .processing && !currentMeeting.transcript.isEmpty
        }
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
        guard !isStartingRecording,
              screen != .recording,
              screen != .paused else { return }
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
        guard !isStartingRecording,
              screen != .recording,
              screen != .paused else { return }
        screen = .settings
        if editingTemplateID == nil {
            let templateID = selectedMeetingID == nil
                ? newMeetingTemplate.id
                : selectedTemplate.id
            selectTemplateForEditing(templateID)
        }
    }

    public func selectTemplateForEditing(_ id: String) {
        guard let template = templates.first(where: { $0.id == id }) else { return }
        editingTemplateID = template.id
        templateNameDraft = template.displayName
        templateInstructionsDraft = template.instructions
        templateSectionsDraft = template.editableStructure
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
        let parsedStructure = SummaryTemplate.parseStructure(templateSectionsDraft)
        let candidate = SummaryTemplate(
            id: existing?.id ?? "user-\(UUID().uuidString.lowercased())",
            displayName: templateNameDraft,
            instructions: templateInstructionsDraft,
            sections: parsedStructure.sections,
            sectionSubtopics: parsedStructure.subtopics.isEmpty ? nil : parsedStructure.subtopics,
            customStructure: templateSectionsDraft,
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
            templateSectionsDraft = validated.editableStructure
            if selectedTemplate.id == validated.id {
                selectedTemplate = validated
            }
            if newMeetingTemplate.id == validated.id {
                newMeetingTemplate = validated
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
            sections: source.sections,
            sectionSubtopics: source.sectionSubtopics,
            customStructure: source.editableStructure
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
                selectedTemplate = updated.first(where: { $0.id == SummaryTemplate.standardMeeting.id })
                    ?? updated.first
                    ?? .standardMeeting
            }
            if newMeetingTemplate.id == template.id {
                newMeetingTemplate = updated.first(where: { $0.id == SummaryTemplate.standardMeeting.id })
                    ?? updated.first
                    ?? .standardMeeting
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
        guard (screen == .empty || screen == .meetingDetail),
              !isStartingRecording,
              !isPreparingForTermination else { return }
        isStartingRecording = true
        defer {
            startingMeetingID = nil
            isStartingRecording = false
            startNextDeferredProcessingIfPossible()
        }

        await suspendBackgroundProcessingForRecording()

        elapsed = 0
        audioLevel = 0
        let meeting = Meeting(
            createdAt: Date(),
            title: calendarEvent?.title ?? "Reunião nova",
            state: .idle,
            templateId: newMeetingTemplate.id,
            customTemplateStructure: newMeetingTemplate.snapshotValue,
            participants: calendarEvent?.participantNames ?? [],
            calendarEventID: calendarEvent?.id,
            scheduledStart: calendarEvent?.start,
            scheduledEnd: calendarEvent?.end
        )
        let meetingID = meeting.id
        startingMeetingID = meetingID
        meetings.insert(meeting, at: 0)
        selectedMeetingID = meetingID
        recordingError = nil
        errorTitle = nil
        shouldOpenSystemAudioSettings = false
        guard persistMeeting(at: 0) else {
            // Without a durable meeting row there is no safe way to associate
            // raw CAF files after a crash. Refuse to open the capture devices
            // instead of presenting a recording that cannot be recovered.
            meetings.removeAll { $0.id == meetingID }
            selectedMeetingID = nil
            audioLevel = 0
            return
        }

        do {
            try await recordingSession.start(meetingID: meetingID)
            guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
                // The capture device is already live. If the durable row vanished
                // through an unexpected external mutation, tear the session down
                // immediately instead of leaving an unfinishable recording behind.
                _ = try? await recordingSession.finish()
                selectedMeetingID = nil
                audioLevel = 0
                screen = .empty
                errorTitle = "Não foi possível iniciar a gravação"
                recordingError = "A reunião em preparação não está mais disponível."
                return
            }
            meetings[index].state = .recording
            persistMeeting(at: index)
            selectedMeetingID = meetingID
            screen = .recording
            startElapsedTimer()
        } catch {
            markRecordingFailed(meetingID: meetingID, error: error)
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
        guard screen == .recording,
              let meetingID = selectedMeetingID,
              !isRecordingTransitionInProgress else { return }
        isRecordingTransitionInProgress = true
        defer { completeRecordingTransition() }
        stopElapsedTimer()
        do {
            _ = try await recordingSession.pause()
            let checkpointWasPersisted = synchronizeActiveMeeting(with: .paused)
            pauseCheckpointBlockedMeetingID = checkpointWasPersisted ? nil : meetingID
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
        guard screen == .paused,
              let meetingID = selectedMeetingID,
              !isRecordingTransitionInProgress,
              !isPreparingForTermination else { return }
        isRecordingTransitionInProgress = true
        defer { completeRecordingTransition() }

        if pauseCheckpointBlockedMeetingID == meetingID {
            // Retry the exact paused checkpoint before opening a new input
            // segment. Until this succeeds, the already finalized segment must
            // remain the sole source of truth and resume stays blocked.
            guard synchronizeActiveMeeting(with: .paused) else { return }
            pauseCheckpointBlockedMeetingID = nil
            if errorTitle == "Não foi possível salvar a reunião" {
                errorTitle = nil
                recordingError = nil
            }
        }

        // Persist the transition before starting hardware. If persistence is
        // unavailable, the durable paused checkpoint remains recoverable and
        // no second, orphan segment is created.
        guard updateSelectedMeetingState(.recording) else {
            pauseCheckpointBlockedMeetingID = meetingID
            return
        }
        do {
            try await recordingSession.resume()
            audioLevel = 0
            screen = .recording
            startElapsedTimer()
        } catch {
            markCurrentRecordingFailed(error)
        }
    }

    public func finishRecording() {
        guard let meetingID = selectedMeetingID else {
            finishMockRecording()
            return
        }
        if isRecordingTransitionInProgress {
            pendingFinishMeetingID = meetingID
            return
        }
        Task { [weak self] in
            await self?.finishActiveRecording()
        }
    }

    public func finishActiveRecording() async {
        _ = await finishActiveRecordingAndReportPersistence()
    }

    @discardableResult
    private func finishActiveRecordingAndReportPersistence() async -> Bool {
        guard screen == .recording || screen == .paused,
              let meetingID = selectedMeetingID else { return false }
        guard !isRecordingTransitionInProgress else {
            // Automatic meeting-end detection can arrive while pause/resume owns
            // the capture session. Preserve that request until the transition
            // reaches a stable state instead of silently losing it.
            pendingFinishMeetingID = meetingID
            return false
        }
        if pendingFinishMeetingID == meetingID {
            pendingFinishMeetingID = nil
        }
        isRecordingTransitionInProgress = true
        stopElapsedTimer()

        // The user-visible meeting ends as soon as the capture devices begin
        // stopping. Export and persistence continue for this immutable ID, so
        // the next recording does not wait for the previous M4A to be produced.
        let finishedAt = Date()
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].state = .preparingAudio
            meetings[index].finishedAt = finishedAt
            persistMeeting(at: index)
        }
        audioLevel = 0
        selectedMeetingID = nil
        screen = .empty
        if pauseCheckpointBlockedMeetingID == meetingID {
            pauseCheckpointBlockedMeetingID = nil
        }

        let finalizationBarrier = RecordingFinalizationBarrier()
        audioFinalizationBarriers[meetingID] = finalizationBarrier
        isRecordingTransitionInProgress = false

        let completionWasPersisted: Bool
        do {
            let finishedSegments = try await recordingSession.finish()
            completionWasPersisted = completeFinalizedRecording(
                meetingID: meetingID,
                segments: finishedSegments,
                finishedAt: finishedAt
            )
            if completionWasPersisted {
                if isPreparingForTermination {
                    deferredProcessingMeetingIDs.insert(meetingID)
                } else {
                    scheduleBackgroundProcessing(for: meetingID)
                }
            }
        } catch {
            completionWasPersisted = markFinalizedRecordingFailed(
                meetingID: meetingID,
                error: error
            )
        }
        if completionWasPersisted {
            unpersistedCriticalMeetingIDs.remove(meetingID)
        } else {
            unpersistedCriticalMeetingIDs.insert(meetingID)
        }
        finalizationBarrier.complete(with: completionWasPersisted)
        audioFinalizationBarriers[meetingID] = nil
        return completionWasPersisted
    }

    private func completeRecordingTransition() {
        isRecordingTransitionInProgress = false
        guard let meetingID = pendingFinishMeetingID else { return }
        pendingFinishMeetingID = nil
        guard !isPreparingForTermination,
              selectedMeetingID == meetingID,
              screen == .recording || screen == .paused else { return }
        Task { [weak self] in
            await self?.finishActiveRecording()
        }
    }

    /// Closes every active capture and waits for all already-detached audio
    /// finalizations before AppKit is allowed to terminate the process. Calls
    /// are coalesced so repeated termination requests cannot stop or persist a
    /// segment twice.
    public func prepareForTermination() async -> Bool {
        if let terminationPreparationBarrier {
            return await terminationPreparationBarrier.wait()
        }

        let terminationBarrier = RecordingFinalizationBarrier()
        terminationPreparationBarrier = terminationBarrier
        isPreparingForTermination = true

        // A start/pause/resume operation owns the capture state until its await
        // returns. Let it reach a stable state, then perform one normal finish.
        while isStartingRecording || isRecordingTransitionInProgress {
            try? await Task.sleep(for: .milliseconds(10))
        }

        var terminationStateIsConsistent = true
        if screen == .recording || screen == .paused {
            _ = await finishActiveRecordingAndReportPersistence()
            terminationStateIsConsistent = screen != .recording && screen != .paused
        }

        while !audioFinalizationBarriers.isEmpty {
            let pendingBarriers = Array(audioFinalizationBarriers.values)
            for barrier in pendingBarriers {
                _ = await barrier.wait()
            }
        }

        // A transient store failure may have happened at the exact moment an
        // audio export completed. Retry the immutable in-memory snapshots now;
        // if any still fails, AppKit cancels termination and a later request
        // will retry instead of silently exiting with orphan segments.
        for meetingID in Array(unpersistedCriticalMeetingIDs) {
            guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
                  persistMeeting(at: index) else {
                terminationStateIsConsistent = false
                continue
            }
            unpersistedCriticalMeetingIDs.remove(meetingID)
        }

        stopElapsedTimer()
        let allCriticalDataWasPersisted = terminationStateIsConsistent
            && unpersistedCriticalMeetingIDs.isEmpty
        if !allCriticalDataWasPersisted {
            isPreparingForTermination = false
        }
        terminationBarrier.complete(with: allCriticalDataWasPersisted)
        terminationPreparationBarrier = nil
        return allCriticalDataWasPersisted
    }

    public func selectMeeting(_ meeting: Meeting) {
        guard !isStartingRecording,
              screen != .recording,
              screen != .paused else { return }
        selectedMeetingID = meeting.id
        selectedTemplate = historicalTemplate(for: meeting)
        customTemplateStructure = meeting.customTemplateStructure
        meetingTitleDraft = meeting.title
        meetingParticipantsDraft = meeting.participantsText
        meetingMetadataMessage = nil
        summaryDraft = meeting.summary
        summaryAutosaveMessage = nil
        detailTab = .summary
        switch meeting.state {
        case .preparingAudio, .transcribing, .transcribed, .summarizing:
            screen = .processing
            requestProcessing(for: meeting.id)
        default:
            screen = .meetingDetail
        }
    }

    /// Applies a template chosen by the user in the meeting detail and, when
    /// there is already a transcript, immediately regenerates the summary.
    /// Programmatic meeting selection intentionally does not call this method.
    public func selectSummaryTemplate(_ template: SummaryTemplate) {
        guard selectedTemplate != template else { return }
        selectedTemplate = template

        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return }

        let previousMeeting = meetings[index]
        meetings[index].templateId = template.id
        meetings[index].customTemplateStructure = template.snapshotValue
        customTemplateStructure = template.snapshotValue

        guard persistMeeting(at: index) else {
            meetings[index] = previousMeeting
            selectedTemplate = historicalTemplate(for: previousMeeting)
            customTemplateStructure = previousMeeting.customTemplateStructure
            return
        }

        guard !meetings[index].transcript.isEmpty else { return }
        enqueueSummaryRegeneration(for: selectedMeetingID)
    }

    public func canDeleteMeeting(_ meeting: Meeting) -> Bool {
        guard !isStartingRecording, meeting.id != startingMeetingID else { return false }
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

    public func updateSummary(_ value: String) {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return }
        summaryDraft = value
        meetings[index].summary = value
        guard persistMeeting(at: index) else {
            summaryAutosaveMessage = "Não foi possível salvar a alteração"
            return
        }
        do {
            // The summary is small; an immediate atomic write makes "alterou,
            // salvou" literal and survives termination on the next keystroke.
            try meetingFileStore.writeSummary(value, meetingID: selectedMeetingID)
            summaryAutosaveMessage = "Salvo automaticamente"
        } catch {
            summaryAutosaveMessage = "Não foi possível salvar a alteração"
        }
    }

    public func retrySummary() {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }),
              !meetings[index].transcript.isEmpty,
              !isCurrentMeetingSummarizing else { return }

        let selectedTemplateSnapshot = selectedTemplate.snapshotValue
        meetings[index].templateId = selectedTemplate.id
        meetings[index].customTemplateStructure = selectedTemplateSnapshot
        customTemplateStructure = selectedTemplateSnapshot
        recordingError = nil
        errorTitle = nil
        guard persistMeeting(at: index) else { return }
        enqueueSummaryRegeneration(for: selectedMeetingID)
    }

    private func enqueueSummaryRegeneration(for meetingID: UUID) {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              !meeting.transcript.isEmpty else { return }

        summaryGenerations[meetingID, default: 0] &+= 1
        deferredProcessingMeetingIDs.insert(meetingID)
        recordingError = nil
        errorTitle = nil
        screen = .processing

        if let activeTask = processingTasks[meetingID] {
            activeTask.cancel()
        } else {
            startSummaryPipeline(for: meetingID)
        }
    }

    /// Reprocesses the locally recorded audio while keeping the last usable
    /// transcript and summary available until a replacement is committed.
    public func retryTranscription() {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }),
              !meetings[index].recordingSegments.isEmpty,
              processingTasks[selectedMeetingID] == nil,
              !isStartingRecording,
              screen != .recording,
              screen != .paused else { return }

        let previousState = meetings[index].state
        meetings[index].state = .transcribing
        guard persistMeeting(at: index) else {
            meetings[index].state = previousState
            return
        }

        recordingError = nil
        errorTitle = nil
        detailTab = .transcript
        screen = .processing
        deferredProcessingMeetingIDs.insert(selectedMeetingID)
        startTranscriptionPipeline(for: selectedMeetingID)
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
            summaryDraft = meetings.first?.summary ?? ""
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
        shouldOpenSystemAudioSettings = false
    }

    private func finishMockRecording() {
        guard screen == .recording || screen == .paused else { return }
        stopElapsedTimer()
        let meeting = Meeting(
            createdAt: Date(),
            recordedDuration: elapsed,
            title: "Reunião nova",
            state: .preparingAudio,
            templateId: newMeetingTemplate.id,
            customTemplateStructure: newMeetingTemplate.snapshotValue
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

    @discardableResult
    private func synchronizeActiveMeeting(
        with state: MeetingState,
        finishedAt: Date? = nil
    ) -> Bool {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return false }
        let segments = recordingSession.segments
        meetings[index].recordingSegments = segments
        meetings[index].recordedDuration = segments.reduce(0) { $0 + $1.recordedDuration }
        meetings[index].state = state
        meetings[index].finishedAt = finishedAt
        elapsed = meetings[index].recordedDuration
        return persistMeeting(at: index)
    }

    @discardableResult
    private func completeFinalizedRecording(
        meetingID: UUID,
        segments: [RecordingSegment],
        finishedAt: Date
    ) -> Bool {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return false }
        meetings[index].recordingSegments = segments
        meetings[index].recordedDuration = segments.reduce(0) { $0 + $1.recordedDuration }
        meetings[index].state = .preparingAudio
        meetings[index].finishedAt = finishedAt
        return persistMeeting(at: index)
    }

    @discardableResult
    private func markFinalizedRecordingFailed(meetingID: UUID, error: Error) -> Bool {
        var failureWasPersisted = false
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].state = .failed
            failureWasPersisted = persistMeeting(at: index)
        }

        // Never interrupt a new live recording with an alert from the previous
        // meeting. The failed item remains visible and its raw files are kept
        // for recovery on the next launch.
        if selectedMeetingID == nil, screen == .empty {
            errorTitle = "Não foi possível finalizar a gravação"
            shouldOpenSystemAudioSettings = false
            recordingError = error.localizedDescription
        }
        if !isPreparingForTermination {
            startNextDeferredProcessingIfPossible()
        }
        return failureWasPersisted
    }

    @discardableResult
    private func updateSelectedMeetingState(_ state: MeetingState) -> Bool {
        guard let selectedMeetingID,
              let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return false }
        let previousState = meetings[index].state
        meetings[index].state = state
        guard persistMeeting(at: index) else {
            meetings[index].state = previousState
            return false
        }
        return true
    }

    private func markCurrentRecordingFailed(_ error: Error) {
        guard let selectedMeetingID else { return }
        markRecordingFailed(meetingID: selectedMeetingID, error: error)
    }

    private func markRecordingFailed(meetingID: UUID, error: Error) {
        stopElapsedTimer()
        var failureWasPersisted = false
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].state = .failed
            failureWasPersisted = persistMeeting(at: index)
        }
        if failureWasPersisted {
            unpersistedCriticalMeetingIDs.remove(meetingID)
        } else {
            unpersistedCriticalMeetingIDs.insert(meetingID)
        }
        audioLevel = 0
        errorTitle = screen == .empty
            ? "Não foi possível iniciar a gravação"
            : "Não foi possível gravar a reunião"
        shouldOpenSystemAudioSettings = error as? RecordingError == .systemAudioPermissionDenied
        recordingError = error.localizedDescription
        screen = .empty
        if !isPreparingForTermination {
            startNextDeferredProcessingIfPossible()
        }
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

    private func scheduleBackgroundProcessing(for meetingID: UUID) {
        deferredProcessingMeetingIDs.insert(meetingID)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.startNextDeferredProcessingIfPossible()
        }
    }

    private func requestProcessing(for meetingID: UUID) {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        guard coldLaunchRecoveryMeetingIDs?.contains(meetingID) != true else {
            // A persisted segment can already exist while recovery is still
            // rebuilding a later orphan. Starting now would permanently omit
            // that later segment from the transcript snapshot.
            deferredProcessingMeetingIDs.insert(meetingID)
            return
        }
        // `.preparingAudio` also covers the short interval in which the raw
        // writers are closed but the final M4A is not ready yet. Opening that
        // meeting must not turn this normal wait into a `noSegments` failure.
        guard !meeting.transcript.isEmpty || !meeting.recordingSegments.isEmpty else { return }
        deferredProcessingMeetingIDs.insert(meetingID)
        if shouldTranscribe(meeting) {
            startTranscriptionPipeline(for: meetingID)
        } else {
            startSummaryPipeline(for: meetingID)
        }
    }

    private func startTranscriptionPipeline(for meetingID: UUID) {
        guard coldLaunchRecoveryMeetingIDs?.contains(meetingID) != true else {
            deferredProcessingMeetingIDs.insert(meetingID)
            return
        }
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              !meeting.recordingSegments.isEmpty else {
            deferredProcessingMeetingIDs.remove(meetingID)
            return
        }
        guard processingTasks[meetingID] == nil else { return }
        guard !isStartingRecording, screen != .recording && screen != .paused else {
            deferredProcessingMeetingIDs.insert(meetingID)
            return
        }
        guard processingTasks.isEmpty else {
            deferredProcessingMeetingIDs.insert(meetingID)
            return
        }
        deferredProcessingMeetingIDs.remove(meetingID)
        processingMeetingIDs.insert(meetingID)
        processingTasks[meetingID] = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.transcribeMeeting(meetingID)
            self.processingMeetingIDs.remove(meetingID)
            self.processingTasks[meetingID] = nil
            self.startNextDeferredProcessingIfPossible()
        }
    }

    private func startSummaryPipeline(for meetingID: UUID) {
        guard coldLaunchRecoveryMeetingIDs?.contains(meetingID) != true else {
            deferredProcessingMeetingIDs.insert(meetingID)
            return
        }
        guard processingTasks[meetingID] == nil else { return }
        guard !isStartingRecording, screen != .recording && screen != .paused else {
            deferredProcessingMeetingIDs.insert(meetingID)
            return
        }
        guard processingTasks.isEmpty else {
            deferredProcessingMeetingIDs.insert(meetingID)
            return
        }
        deferredProcessingMeetingIDs.remove(meetingID)
        processingMeetingIDs.insert(meetingID)
        let generation = summaryGenerations[meetingID, default: 0]
        processingTasks[meetingID] = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.summarizeMeeting(meetingID, generation: generation)
            self.processingMeetingIDs.remove(meetingID)
            self.processingTasks[meetingID] = nil
            self.startNextDeferredProcessingIfPossible()
        }
    }

    private func resumePendingProcessing() {
        for meeting in meetings {
            guard processingTasks[meeting.id] == nil else { continue }
            switch meeting.state {
            case .preparingAudio, .transcribing:
                deferredProcessingMeetingIDs.insert(meeting.id)
            case .summarizing:
                deferredProcessingMeetingIDs.insert(meeting.id)
            case .transcribed:
                deferredProcessingMeetingIDs.insert(meeting.id)
            default:
                continue
            }
        }
        startNextDeferredProcessingIfPossible()
    }

    private enum InterruptedRecoveryControl: Error {
        case meetingRemoved
    }

    private func recoverInterruptedRecordings() async {
        guard !Task.isCancelled,
              let coldLaunchRecoveryMeetingIDs else { return }
        let protectedMeetingIDs = interruptedRecoveryProtectedMeetingIDs
        let interruptedIDs = meetings
            .filter {
                coldLaunchRecoveryMeetingIDs.contains($0.id)
                    && !protectedMeetingIDs.contains($0.id)
                    && ($0.state == .recording
                        || $0.state == .paused
                        || ($0.state == .preparingAudio && $0.transcript.isEmpty)
                        || ($0.state == .idle && $0.recordingSegments.isEmpty)
                        || ($0.state == .failed && $0.transcript.isEmpty))
            }
            .map(\.id)

        for meetingID in interruptedIDs {
            guard !Task.isCancelled else { return }
            defer {
                // Release this meeting independently as soon as every orphan
                // sequence has been reconciled. An explicit user request that
                // was deferred above can now take a complete segment snapshot.
                self.coldLaunchRecoveryMeetingIDs?.remove(meetingID)
                startNextDeferredProcessingIfPossible()
            }
            guard let interruptedMeeting = meetings.first(where: { $0.id == meetingID }) else { continue }

            do {
                var validExistingSequences: Set<Int> = []
                for segment in interruptedMeeting.recordingSegments {
                    let duration = await interruptedRecordingAudioDuration(at: segment.fileURL)
                    try ensureInterruptedRecoveryCanContinue(for: meetingID)
                    if duration != nil {
                        validExistingSequences.insert(segment.sequence)
                    }
                }
                let orphanSequences = try interruptedSegmentSequences(onDiskFor: meetingID)
                    .filter { sequence in
                        if !validExistingSequences.contains(sequence) {
                            return true
                        }
                        return try interruptedSequenceHasRawSourcesOrManifest(
                            meetingID: meetingID,
                            sequence: sequence
                        )
                    }
                var failedSequences: [Int] = []

                for sequence in orphanSequences {
                    do {
                        try ensureInterruptedRecoveryCanContinue(for: meetingID)
                        guard let recoveredSegment = try await recoverInterruptedSegment(
                            meetingID: meetingID,
                            sequence: sequence
                        ) else { continue }
                        try ensureInterruptedRecoveryCanContinue(for: meetingID)
                        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else {
                            throw InterruptedRecoveryControl.meetingRemoved
                        }

                        var segments = meetings[index].recordingSegments
                        if let replacementIndex = segments.firstIndex(where: { $0.sequence == sequence }) {
                            let existingSegment = segments[replacementIndex]
                            segments[replacementIndex] = RecordingSegment(
                                id: existingSegment.id,
                                meetingID: meetingID,
                                sequence: sequence,
                                fileURL: recoveredSegment.fileURL,
                                recordedDuration: recoveredSegment.recordedDuration,
                                createdAt: existingSegment.createdAt,
                                captureWarning: recoveredSegment.captureWarning
                            )
                        } else {
                            guard !segments.contains(where: { $0.fileURL == recoveredSegment.fileURL }) else {
                                continue
                            }
                            let persistedSequence = segments.contains(where: { $0.sequence == sequence })
                                ? (segments.map(\.sequence).max() ?? 0) + 1
                                : sequence
                            segments.append(RecordingSegment(
                                id: recoveredSegment.id,
                                meetingID: meetingID,
                                sequence: persistedSequence,
                                fileURL: recoveredSegment.fileURL,
                                recordedDuration: recoveredSegment.recordedDuration,
                                createdAt: recoveredSegment.createdAt,
                                captureWarning: recoveredSegment.captureWarning
                            ))
                        }
                        meetings[index].recordingSegments = segments.sorted { $0.sequence < $1.sequence }
                        meetings[index].recordedDuration = segments.reduce(0) { $0 + $1.recordedDuration }
                        meetings[index].finishedAt = meetings[index].finishedAt ?? Date()
                        meetings[index].state = .preparingAudio
                        persistMeeting(at: index)
                    } catch is CancellationError {
                        return
                    } catch InterruptedRecoveryControl.meetingRemoved {
                        break
                    } catch {
                        guard !Task.isCancelled else { return }
                        guard meetings.contains(where: { $0.id == meetingID }) else { break }
                        failedSequences.append(sequence)
                    }
                }

                try ensureInterruptedRecoveryCanContinue(for: meetingID)
                guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { continue }
                if meetings[index].recordingSegments.isEmpty {
                    meetings[index].state = .failed
                    persistMeeting(at: index)
                    continue
                }

                if !failedSequences.isEmpty,
                   let lastSegmentIndex = meetings[index].recordingSegments.indices.last {
                    let segment = meetings[index].recordingSegments[lastSegmentIndex]
                    let failedList = failedSequences.sorted().map(String.init).joined(separator: ", ")
                    meetings[index].recordingSegments[lastSegmentIndex] = RecordingSegment(
                        id: segment.id,
                        meetingID: segment.meetingID,
                        sequence: segment.sequence,
                        fileURL: segment.fileURL,
                        recordedDuration: segment.recordedDuration,
                        createdAt: segment.createdAt,
                        captureWarning: joinedCaptureWarnings([
                            segment.captureWarning,
                            "Não foi possível recuperar os segmentos \(failedList); os arquivos brutos foram preservados."
                        ])
                    )
                }
                meetings[index].recordedDuration = meetings[index].recordingSegments.reduce(0) {
                    $0 + $1.recordedDuration
                }
                meetings[index].finishedAt = meetings[index].finishedAt ?? Date()
                meetings[index].state = .preparingAudio
                persistMeeting(at: index)
            } catch is CancellationError {
                return
            } catch InterruptedRecoveryControl.meetingRemoved {
                continue
            } catch {
                guard !Task.isCancelled else { return }
                guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { continue }
                meetings[index].state = meetings[index].recordingSegments.isEmpty ? .failed : .preparingAudio
                persistMeeting(at: index)
            }
        }
    }

    private func interruptedSegmentSequences(onDiskFor meetingID: UUID) throws -> [Int] {
        let probeURL = try meetingFileStore.makeSegmentURL(meetingID: meetingID, sequence: 1)
        let directory = probeURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var sequences: Set<Int> = []

        for name in names where name.hasPrefix("segment-") {
            let suffix = name.dropFirst("segment-".count)
            let digits = suffix.prefix(while: \.isNumber)
            guard !digits.isEmpty,
                  let sequence = Int(digits),
                  sequence > 0 else { continue }
            let remainder = suffix.dropFirst(digits.count)
            guard remainder == ".m4a"
                    || remainder == ".caf"
                    || remainder == "-system.caf"
                    || remainder == "-microphone.caf"
                    || remainder == "-capture.json" else { continue }
            sequences.insert(sequence)
        }
        return sequences.sorted()
    }

    private func interruptedSequenceHasRawSourcesOrManifest(
        meetingID: UUID,
        sequence: Int
    ) throws -> Bool {
        let outputURL = try meetingFileStore.makeSegmentURL(
            meetingID: meetingID,
            sequence: sequence
        )
        let stem = outputURL.deletingPathExtension().lastPathComponent
        let directory = outputURL.deletingLastPathComponent()
        let recoveryURLs = [
            directory.appendingPathComponent("\(stem)-system.caf"),
            directory.appendingPathComponent("\(stem)-microphone.caf"),
            AudioCaptureRecoveryManifest.manifestURL(for: outputURL)
        ]
        return recoveryURLs.contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func recoverInterruptedSegment(
        meetingID: UUID,
        sequence: Int
    ) async throws -> RecordingSegment? {
        try ensureInterruptedRecoveryCanContinue(for: meetingID)
        let canonicalOutputURL = try meetingFileStore.makeSegmentURL(
            meetingID: meetingID,
            sequence: sequence
        )
        let stem = canonicalOutputURL.deletingPathExtension().lastPathComponent
        let directory = canonicalOutputURL.deletingLastPathComponent()
        let legacyOutputURL = directory.appendingPathComponent("\(stem).caf")
        let outputURL = FileManager.default.fileExists(atPath: canonicalOutputURL.path)
            ? canonicalOutputURL
            : legacyOutputURL
        let systemURL = directory.appendingPathComponent("\(stem)-system.caf")
        let microphoneURL = directory.appendingPathComponent("\(stem)-microphone.caf")
        let recoveryManifest = try? AudioCaptureRecoveryManifest.load(for: canonicalOutputURL)

        let outputDuration = await interruptedRecordingAudioDuration(at: outputURL)
        try ensureInterruptedRecoveryCanContinue(for: meetingID)
        let systemFileExists = FileManager.default.fileExists(atPath: systemURL.path)
        let microphoneFileExists = FileManager.default.fileExists(atPath: microphoneURL.path)
        let systemDuration: TimeInterval?
        if systemFileExists {
            systemDuration = await interruptedRecordingAudioDuration(at: systemURL)
            try ensureInterruptedRecoveryCanContinue(for: meetingID)
        } else {
            systemDuration = nil
        }
        let microphoneDuration: TimeInterval?
        if microphoneFileExists {
            microphoneDuration = await interruptedRecordingAudioDuration(at: microphoneURL)
            try ensureInterruptedRecoveryCanContinue(for: meetingID)
        } else {
            microphoneDuration = nil
        }

        let systemIsValid = systemDuration != nil
        let microphoneIsValid = microphoneDuration != nil
        let rawSourceOffsets = recoveryManifest?.sourceOffsets(
            includeSystemAudio: systemIsValid,
            includeMicrophoneAudio: microphoneIsValid
        )
        let systemIsTruncated = systemDuration.map {
            interruptedOutputIsTruncated(
                actualDuration: $0,
                expectedDuration: expectedInterruptedSourceDuration(
                    manifest: recoveryManifest,
                    sourceStartedAtUptime: recoveryManifest?.systemStartedAtUptime
                )
            )
        } ?? false
        let microphoneIsTruncated = microphoneDuration.map {
            interruptedOutputIsTruncated(
                actualDuration: $0,
                expectedDuration: expectedInterruptedSourceDuration(
                    manifest: recoveryManifest,
                    sourceStartedAtUptime: recoveryManifest?.microphoneStartedAtUptime
                )
            )
        } ?? false
        let systemWasExplicitlyExcluded = recoveryManifest?.phase == .finalized
            && recoveryManifest?.includedSystemAudio == false
        let microphoneWasExplicitlyExcluded = recoveryManifest?.phase == .finalized
            && recoveryManifest?.includedMicrophoneAudio == false
        let includeSystemAudio = systemIsValid
            && !systemWasExplicitlyExcluded
        let includeMicrophoneAudio = microphoneIsValid
            && !microphoneWasExplicitlyExcluded
        let includedSourceOffsets = recoveryManifest?.sourceOffsets(
            includeSystemAudio: includeSystemAudio,
            includeMicrophoneAudio: includeMicrophoneAudio
        )
        let timingMetadataIsMissing = includeSystemAudio
            && includeMicrophoneAudio
            && includedSourceOffsets == nil
        let expectedDuration = expectedInterruptedTimelineDuration(
            manifest: recoveryManifest,
            systemDuration: systemDuration,
            microphoneDuration: microphoneDuration,
            sourceOffsets: rawSourceOffsets
        )
        let outputIsTruncated = outputDuration.map {
            interruptedOutputIsTruncated(actualDuration: $0, expectedDuration: expectedDuration)
        } ?? false

        if let outputDuration, !outputIsTruncated {
            return RecordingSegment(
                meetingID: meetingID,
                sequence: sequence,
                fileURL: outputURL,
                recordedDuration: outputDuration,
                captureWarning: warningForRecoveredFinalOutput(
                    manifest: recoveryManifest,
                    systemFileExists: systemFileExists,
                    microphoneFileExists: microphoneFileExists,
                    systemIsValid: systemIsValid,
                    microphoneIsValid: microphoneIsValid,
                    timingMetadataIsMissing: timingMetadataIsMissing
                )
            )
        }

        guard systemFileExists || microphoneFileExists else {
            if outputIsTruncated {
                throw RecordingError.fileWriteFailed(
                    "O segmento \(sequence) está incompleto e não possui áudios brutos para reconstrução."
                )
            }
            return nil
        }
        guard includeSystemAudio || includeMicrophoneAudio else {
            throw RecordingError.fileWriteFailed(
                "Nenhuma fonte bruta completa e confiável do segmento \(sequence) está disponível."
            )
        }

        let finalizedURL = try await combineInterruptedRecordingAudio(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: canonicalOutputURL,
            systemStartOffset: includedSourceOffsets?.system ?? 0,
            microphoneStartOffset: includedSourceOffsets?.microphone ?? 0,
            includeSystemAudio: includeSystemAudio,
            includeMicrophoneAudio: includeMicrophoneAudio
        )
        try ensureInterruptedRecoveryCanContinue(for: meetingID)
        guard let duration = await interruptedRecordingAudioDuration(at: finalizedURL) else {
            try ensureInterruptedRecoveryCanContinue(for: meetingID)
            throw RecordingError.fileWriteFailed(
                "O segmento \(sequence) reconstruído não pôde ser validado."
            )
        }
        try ensureInterruptedRecoveryCanContinue(for: meetingID)
        let expectedRebuiltDuration = expectedInterruptedTimelineDuration(
            manifest: nil,
            systemDuration: includeSystemAudio ? systemDuration : nil,
            microphoneDuration: includeMicrophoneAudio ? microphoneDuration : nil,
            sourceOffsets: includedSourceOffsets
        )
        guard !interruptedOutputIsTruncated(
            actualDuration: duration,
            expectedDuration: expectedRebuiltDuration
        ) else {
            throw RecordingError.fileWriteFailed(
                "O segmento \(sequence) reconstruído não preservou toda a duração disponível nas fontes brutas."
            )
        }

        let captureWarning = joinedCaptureWarnings([
            warningForRecoveredRawSources(
                manifest: recoveryManifest,
                systemFileExists: systemFileExists,
                microphoneFileExists: microphoneFileExists,
                systemIsValid: systemIsValid,
                microphoneIsValid: microphoneIsValid,
                systemIsTruncated: systemIsTruncated,
                microphoneIsTruncated: microphoneIsTruncated,
                systemWasExplicitlyExcluded: systemWasExplicitlyExcluded,
                microphoneWasExplicitlyExcluded: microphoneWasExplicitlyExcluded,
                includeSystemAudio: includeSystemAudio,
                includeMicrophoneAudio: includeMicrophoneAudio,
                timingMetadataIsMissing: timingMetadataIsMissing
            ),
            outputIsTruncated
                ? "O arquivo final interrompido estava incompleto e foi reconstruído a partir dos áudios brutos."
                : nil
        ])
        if captureWarning == nil {
            try ensureInterruptedRecoveryCanContinue(for: meetingID)
            for temporaryURL in [systemURL, microphoneURL] where temporaryURL != finalizedURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            try? FileManager.default.removeItem(
                at: AudioCaptureRecoveryManifest.manifestURL(for: canonicalOutputURL)
            )
        }
        return RecordingSegment(
            meetingID: meetingID,
            sequence: sequence,
            fileURL: finalizedURL,
            recordedDuration: duration,
            captureWarning: captureWarning
        )
    }

    private func ensureInterruptedRecoveryCanContinue(for meetingID: UUID) throws {
        try Task.checkCancellation()
        guard coldLaunchRecoveryMeetingIDs?.contains(meetingID) == true,
              !interruptedRecoveryProtectedMeetingIDs.contains(meetingID),
              meetings.contains(where: { $0.id == meetingID }) else {
            // The same control path covers deletion and a row that acquired a
            // live capture owner after an asynchronous validation boundary.
            throw InterruptedRecoveryControl.meetingRemoved
        }
    }

    private func interruptedRecordingAudioDuration(at url: URL) async -> TimeInterval? {
        if let interruptedAudioDurationValidator {
            return await interruptedAudioDurationValidator(url)
        }
        return await validAudioDuration(at: url)
    }

    private func combineInterruptedRecordingAudio(
        systemURL: URL,
        microphoneURL: URL,
        outputURL: URL,
        systemStartOffset: TimeInterval,
        microphoneStartOffset: TimeInterval,
        includeSystemAudio: Bool,
        includeMicrophoneAudio: Bool
    ) async throws -> URL {
        if let interruptedAudioCombiner {
            return try await interruptedAudioCombiner(
                systemURL,
                microphoneURL,
                outputURL,
                systemStartOffset,
                microphoneStartOffset,
                includeSystemAudio,
                includeMicrophoneAudio
            )
        }
        return try await CoreAudioTapCaptureService.combineAudioTracks(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            systemStartOffset: systemStartOffset,
            microphoneStartOffset: microphoneStartOffset,
            includeSystemAudio: includeSystemAudio,
            includeMicrophoneAudio: includeMicrophoneAudio
        )
    }

    private func interruptedRecordingCaptureWarning(
        systemIsValid: Bool,
        microphoneIsValid: Bool,
        timingMetadataIsMissing: Bool
    ) -> String? {
        var warnings: [String] = []
        switch (systemIsValid, microphoneIsValid) {
        case (true, true):
            break
        case (true, false):
            warnings.append(
                "Recuperação parcial: o áudio do microfone estava ausente ou corrompido; somente o áudio do sistema foi preservado."
            )
        case (false, true):
            warnings.append(
                "Recuperação parcial: o áudio do sistema estava ausente ou corrompido; somente o áudio do microfone foi preservado."
            )
        case (false, false):
            warnings.append(
                "Recuperação parcial: as fontes de áudio do sistema e do microfone não puderam ser validadas."
            )
        }
        if timingMetadataIsMissing {
            warnings.append(
                "A sincronização original entre o microfone e o áudio do sistema não estava disponível."
            )
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    private func warningForRecoveredFinalOutput(
        manifest: AudioCaptureRecoveryManifest?,
        systemFileExists: Bool,
        microphoneFileExists: Bool,
        systemIsValid: Bool,
        microphoneIsValid: Bool,
        timingMetadataIsMissing: Bool
    ) -> String? {
        if let warning = manifest?.finalizationWarning?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !warning.isEmpty {
            return warning
        }

        // A finalized marker is written atomically before cleanup. Its source
        // flags remain authoritative if the process exits halfway through
        // deleting otherwise healthy raw CAF files.
        if manifest?.phase == .finalized,
           let includedSystemAudio = manifest?.includedSystemAudio,
           let includedMicrophoneAudio = manifest?.includedMicrophoneAudio {
            return interruptedRecordingCaptureWarning(
                systemIsValid: includedSystemAudio,
                microphoneIsValid: includedMicrophoneAudio,
                timingMetadataIsMissing: false
            )
        }

        guard manifest != nil || systemFileExists || microphoneFileExists else { return nil }
        return interruptedRecordingCaptureWarning(
            systemIsValid: systemIsValid,
            microphoneIsValid: microphoneIsValid,
            timingMetadataIsMissing: timingMetadataIsMissing
        )
    }

    private func warningForRecoveredRawSources(
        manifest: AudioCaptureRecoveryManifest?,
        systemFileExists: Bool,
        microphoneFileExists: Bool,
        systemIsValid: Bool,
        microphoneIsValid: Bool,
        systemIsTruncated: Bool,
        microphoneIsTruncated: Bool,
        systemWasExplicitlyExcluded: Bool,
        microphoneWasExplicitlyExcluded: Bool,
        includeSystemAudio: Bool,
        includeMicrophoneAudio: Bool,
        timingMetadataIsMissing: Bool
    ) -> String? {
        var warnings: [String?] = []
        if let finalizationWarning = manifest?.finalizationWarning,
           !finalizationWarning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append(finalizationWarning)
        }
        if systemIsTruncated {
            warnings.append(includeSystemAudio
                ? "Recuperação parcial: o áudio do sistema estava truncado; o trecho decodificável foi preservado."
                : "Recuperação parcial: o áudio do sistema estava truncado e foi excluído."
            )
        } else if systemWasExplicitlyExcluded, manifest?.finalizationWarning == nil {
            warnings.append(
                "Recuperação parcial: o áudio do sistema foi marcado como não confiável na finalização e foi excluído."
            )
        }
        if microphoneIsTruncated {
            warnings.append(includeMicrophoneAudio
                ? "Recuperação parcial: o áudio do microfone estava truncado; o trecho decodificável foi preservado."
                : "Recuperação parcial: o áudio do microfone estava truncado e foi excluído."
            )
        } else if microphoneWasExplicitlyExcluded, manifest?.finalizationWarning == nil {
            warnings.append(
                "Recuperação parcial: o áudio do microfone foi marcado como não confiável na finalização e foi excluído."
            )
        }

        if warnings.compactMap({ $0 }).isEmpty {
            warnings.append(interruptedRecordingCaptureWarning(
                systemIsValid: includeSystemAudio,
                microphoneIsValid: includeMicrophoneAudio,
                timingMetadataIsMissing: timingMetadataIsMissing
            ))
        } else if timingMetadataIsMissing {
            warnings.append(
                "A sincronização original entre o microfone e o áudio do sistema não estava disponível."
            )
        }

        // When a manifest exists but a source file disappeared or became
        // undecodable, retain that fact even if another degradation reason was
        // already recorded.
        if !systemIsValid,
           !systemWasExplicitlyExcluded,
           !systemIsTruncated,
           (manifest != nil || systemFileExists) {
            warnings.append("O áudio bruto do sistema estava ausente ou corrompido.")
        }
        if !microphoneIsValid,
           !microphoneWasExplicitlyExcluded,
           !microphoneIsTruncated,
           (manifest != nil || microphoneFileExists) {
            warnings.append("O áudio bruto do microfone estava ausente ou corrompido.")
        }
        return joinedCaptureWarnings(warnings)
    }

    private func expectedInterruptedSourceDuration(
        manifest: AudioCaptureRecoveryManifest?,
        sourceStartedAtUptime: TimeInterval?
    ) -> TimeInterval? {
        guard let manifest,
              manifest.observedDuration.isFinite,
              manifest.observedDuration > 0 else { return nil }
        let timelineOrigin = [
            manifest.systemStartedAtUptime,
            manifest.microphoneStartedAtUptime
        ].compactMap { value -> TimeInterval? in
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }.min()
        guard let sourceStartedAtUptime,
              sourceStartedAtUptime.isFinite,
              sourceStartedAtUptime >= 0,
              let timelineOrigin else {
            return manifest.observedDuration
        }
        let offset = max(0, sourceStartedAtUptime - timelineOrigin)
        return max(0, manifest.observedDuration - offset)
    }

    private func expectedInterruptedTimelineDuration(
        manifest: AudioCaptureRecoveryManifest?,
        systemDuration: TimeInterval?,
        microphoneDuration: TimeInterval?,
        sourceOffsets: AudioCaptureRecoveryManifest.SourceOffsets?
    ) -> TimeInterval? {
        var candidates: [TimeInterval] = []
        if let observedDuration = manifest?.observedDuration,
           observedDuration.isFinite,
           observedDuration > 0 {
            candidates.append(observedDuration)
        }
        if let systemDuration, systemDuration.isFinite, systemDuration > 0 {
            candidates.append(systemDuration + (sourceOffsets?.system ?? 0))
        }
        if let microphoneDuration, microphoneDuration.isFinite, microphoneDuration > 0 {
            candidates.append(microphoneDuration + (sourceOffsets?.microphone ?? 0))
        }
        return candidates.max()
    }

    private func interruptedOutputIsTruncated(
        actualDuration: TimeInterval,
        expectedDuration: TimeInterval?
    ) -> Bool {
        guard actualDuration.isFinite,
              actualDuration > 0,
              let expectedDuration,
              expectedDuration.isFinite,
              expectedDuration > 0 else { return false }
        // Container rounding is sub-second in normal captures. Keep a small
        // proportional allowance for short files, but cap it so long meetings
        // can never hide minutes of lost audio.
        let toleratedShortfall = min(2, max(0.5, expectedDuration * 0.01))
        return actualDuration + toleratedShortfall < expectedDuration
    }

    private func joinedCaptureWarnings(_ warnings: [String?]) -> String? {
        var uniqueWarnings: [String] = []
        for warning in warnings.compactMap({ $0 }) {
            let clean = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, !uniqueWarnings.contains(clean) {
                uniqueWarnings.append(clean)
            }
        }
        return uniqueWarnings.isEmpty ? nil : uniqueWarnings.joined(separator: " ")
    }

    private func validAudioDuration(at url: URL) async -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { return nil }
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return duration.isValid && seconds.isFinite && seconds > 0 ? seconds : nil
        } catch {
            return nil
        }
    }

    private func startNextDeferredProcessingIfPossible() {
        guard !isStartingRecording,
              screen != .recording,
              screen != .paused,
              processingTasks.isEmpty else { return }
        let nextMeeting = meetings
            .filter {
                deferredProcessingMeetingIDs.contains($0.id)
                    && coldLaunchRecoveryMeetingIDs?.contains($0.id) != true
            }
            .sorted { $0.createdAt < $1.createdAt }
            .first
        guard let nextMeeting else { return }
        if shouldTranscribe(nextMeeting) {
            startTranscriptionPipeline(for: nextMeeting.id)
        } else {
            startSummaryPipeline(for: nextMeeting.id)
        }
    }

    private func shouldTranscribe(_ meeting: Meeting) -> Bool {
        switch meeting.state {
        case .preparingAudio, .transcribing:
            return true
        default:
            return meeting.transcript.isEmpty
        }
    }

    private func suspendBackgroundProcessingForRecording() async {
        let activeTasks = processingTasks
        for meetingID in activeTasks.keys {
            deferredProcessingMeetingIDs.insert(meetingID)
            activeTasks[meetingID]?.cancel()
            if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
                let wasReplacingExistingTranscript = meetings[index].state == .transcribing
                    && !meetings[index].transcript.isEmpty
                meetings[index].state = wasReplacingExistingTranscript
                    ? .transcribing
                    : (meetings[index].transcript.isEmpty ? .preparingAudio : .transcribed)
                persistMeeting(at: index)
            }
        }

        // Cancelling the Swift task immediately signals whisper.cpp, but model
        // loading itself is not interruptible. Wait until every worker has
        // actually exited so capture never competes with model initialization,
        // Metal buffers, or decoding from the previous meeting.
        for task in activeTasks.values {
            await task.value
        }
    }

    private func transcribeMeeting(_ meetingID: UUID) async {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }

        let stableMeeting = meetings[index]
        let hadPreviousTranscript = !stableMeeting.transcript.isEmpty
        var didCommitReplacement = false
        meetings[index].state = .transcribing
        persistMeeting(at: index)
        do {
            try Task.checkCancellation()
            let transcription = try await transcriptionService.generateTranscript(
                segments: meetings[index].recordingSegments
            )
            guard let completedIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            var completedMeeting = meetings[completedIndex]
            completedMeeting.transcript = transcription.transcript
            // A summary is evidence derived from one exact transcript. Never
            // leave the previous summary attached to replacement text.
            completedMeeting.summary = ""
            completedMeeting.state = .transcribed
            for segmentIndex in completedMeeting.recordingSegments.indices {
                let sequence = completedMeeting.recordingSegments[segmentIndex].sequence
                guard let warnings = transcription.segmentWarnings[sequence],
                      !warnings.isEmpty else { continue }
                completedMeeting.recordingSegments[segmentIndex].captureWarning = joinedCaptureWarnings([
                    completedMeeting.recordingSegments[segmentIndex].captureWarning,
                    warnings.joined(separator: " ")
                ])
            }
            guard commitGeneratedContent(
                completedMeeting,
                replacing: stableMeeting,
                at: completedIndex,
                failureTitle: "Não foi possível salvar a transcrição"
            ) else {
                meetings[completedIndex].state = .failed
                persistMeeting(at: completedIndex)
                presentProcessingFailureIfVisible(
                    meetingID: meetingID,
                    title: errorTitle ?? "Não foi possível salvar a transcrição",
                    message: recordingError ?? "A transcrição anterior foi preservada.",
                    detailTab: .transcript
                )
                return
            }
            if selectedMeetingID == meetingID {
                summaryDraft = ""
            }
            didCommitReplacement = true
            try Task.checkCancellation()
            await summarizeMeeting(
                meetingID,
                generation: summaryGenerations[meetingID, default: 0]
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                if let pendingIndex = meetings.firstIndex(where: { $0.id == meetingID }) {
                    if didCommitReplacement {
                        meetings[pendingIndex].state = .transcribed
                    } else {
                        meetings[pendingIndex].state = hadPreviousTranscript ? .transcribing : .preparingAudio
                    }
                    persistMeeting(at: pendingIndex)
                }
                deferredProcessingMeetingIDs.insert(meetingID)
                return
            }
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

    private func summarizeMeeting(_ meetingID: UUID, generation: UInt64) async {
        guard summaryGenerations[meetingID, default: 0] == generation,
              let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }

        let stableMeeting = meetings[index]
        meetings[index].state = .summarizing
        persistMeeting(at: index)
        let meeting = meetings[index]
        let template = historicalTemplate(for: meeting)

        do {
            try Task.checkCancellation()
            let summary = try await summaryService.generateSummaryText(
                transcript: meeting.transcript,
                template: template
            )
            try Task.checkCancellation()
            guard summaryGenerations[meetingID, default: 0] == generation,
                  let completedIndex = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            var completedMeeting = meetings[completedIndex]
            completedMeeting.summary = summary
            completedMeeting.state = .completed
            guard commitGeneratedContent(
                completedMeeting,
                replacing: stableMeeting,
                at: completedIndex,
                failureTitle: "Não foi possível salvar o resumo"
            ) else {
                meetings[completedIndex].state = .failed
                persistMeeting(at: completedIndex)
                presentProcessingFailureIfVisible(
                    meetingID: meetingID,
                    title: errorTitle ?? "Não foi possível salvar o resumo",
                    message: recordingError ?? "O conteúdo anterior foi preservado.",
                    detailTab: .transcript
                )
                return
            }
            if selectedMeetingID == meetingID, screen == .processing {
                summaryDraft = summary
                detailTab = .summary
                screen = .meetingDetail
            }
        } catch {
            guard summaryGenerations[meetingID, default: 0] == generation else { return }
            if error is CancellationError || Task.isCancelled {
                if let pendingIndex = meetings.firstIndex(where: { $0.id == meetingID }) {
                    meetings[pendingIndex].state = .transcribed
                    persistMeeting(at: pendingIndex)
                }
                deferredProcessingMeetingIDs.insert(meetingID)
                return
            }
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

    private func historicalTemplate(for meeting: Meeting) -> SummaryTemplate {
        SummaryTemplate.restoringSnapshot(
            meeting.customTemplateStructure,
            templateID: meeting.templateId,
            fallback: templates.first(where: { $0.id == meeting.templateId })
        )
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

    /// Commits generated content to the canonical meeting store first, then
    /// mirrors it to the human-readable files. Any failure restores the last
    /// coherent transcript/summary pair instead of leaving mixed generations.
    private func commitGeneratedContent(
        _ updatedMeeting: Meeting,
        replacing previousMeeting: Meeting,
        at index: Int,
        failureTitle: String
    ) -> Bool {
        guard meetings.indices.contains(index),
              meetings[index].id == updatedMeeting.id,
              previousMeeting.id == updatedMeeting.id else { return false }

        meetings[index] = updatedMeeting
        guard persistMeeting(at: index) else {
            meetings[index] = previousMeeting
            try? store.save(previousMeeting)
            return false
        }

        do {
            if previousMeeting.transcript != updatedMeeting.transcript {
                try meetingFileStore.writeTranscript(
                    updatedMeeting.transcript,
                    meetingID: updatedMeeting.id
                )
            }
            if previousMeeting.summary != updatedMeeting.summary {
                try meetingFileStore.writeSummary(
                    updatedMeeting.summary,
                    meetingID: updatedMeeting.id
                )
            }
            return true
        } catch {
            meetings[index] = previousMeeting
            try? store.save(previousMeeting)
            if previousMeeting.transcript != updatedMeeting.transcript {
                try? meetingFileStore.writeTranscript(
                    previousMeeting.transcript,
                    meetingID: previousMeeting.id
                )
            }
            if previousMeeting.summary != updatedMeeting.summary {
                try? meetingFileStore.writeSummary(
                    previousMeeting.summary,
                    meetingID: previousMeeting.id
                )
            }
            errorTitle = failureTitle
            recordingError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func persistMeeting(at index: Int) -> Bool {
        guard meetings.indices.contains(index) else { return false }
        do {
            try store.save(meetings[index])
            return true
        } catch {
            if recordingError == nil {
                errorTitle = "Não foi possível salvar a reunião"
                recordingError = error.localizedDescription
            }
            return false
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
