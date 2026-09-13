import XCTest
@testable import QapiaCore

@MainActor
final class QapiaTests: XCTestCase {
    func testApplicationServicesPrepareLocalResourcesOnLaunch() async {
        let preparer = FakeLocalResourcePreparer()
        let viewModel = MeetingViewModel(
            store: EmptyMeetingStore(),
            clipboard: MemoryClipboardService(),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            resourcePreparer: preparer
        )

        viewModel.startApplicationServices()
        await waitUntil {
            viewModel.isSetupBannerVisible
        }
        await waitUntil {
            preparer.prepareCountValue > 0
        }

        XCTAssertEqual(preparer.prepareCountValue, 1)
        XCTAssertTrue(viewModel.isSetupBannerVisible)
    }

    func testApplicationLaunchResumesSummaryAfterCompletedTranscription() async throws {
        let meeting = Meeting(
            title: "Retomar resumo",
            state: .transcribed,
            transcript: "Transcrição já persistida."
        )
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            clipboard: MemoryClipboardService(),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo\n\nRetomado automaticamente."),
                fileStore: LocalMeetingFileStore(
                    rootURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                )
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            resourcePreparer: FakeLocalResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil {
            viewModel.meetings.first?.state == .completed
        }

        XCTAssertEqual(viewModel.meetings.first?.summary, "# Resumo\n\nRetomado automaticamente.")
    }

    func testSupportedMeetingWindowDetectorRecognizesMeetTeamsAndZoom() {
        XCTAssertTrue(SupportedMeetingWindowDetector.matches(
            applicationName: "Google Chrome",
            windowTitle: "Daily de produto - Google Meet"
        ))
        XCTAssertTrue(SupportedMeetingWindowDetector.matches(
            applicationName: "Microsoft Teams",
            windowTitle: "Reunião com o time"
        ))
        XCTAssertTrue(SupportedMeetingWindowDetector.matches(
            applicationName: "zoom.us",
            windowTitle: "Zoom Meeting"
        ))
        XCTAssertFalse(SupportedMeetingWindowDetector.matches(
            applicationName: "Google Chrome",
            windowTitle: "QAP.ia — documentação"
        ))
    }

    func testMeetingEndDetectionRequiresWindowAndContinuousSilence() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = MeetingEndDetectionState()

        XCTAssertFalse(state.observe(hasMeetingWindow: false, audioLevel: 0, at: start, gracePeriod: 30))
        XCTAssertFalse(state.observe(hasMeetingWindow: true, audioLevel: 0.2, at: start, gracePeriod: 30))
        XCTAssertTrue(state.hasDetectedMeetingWindow)
        XCTAssertFalse(state.observe(hasMeetingWindow: false, audioLevel: 0.4, at: start.addingTimeInterval(5), gracePeriod: 30))
        XCTAssertFalse(state.observe(hasMeetingWindow: false, audioLevel: 0, at: start.addingTimeInterval(10), gracePeriod: 30))
        XCTAssertFalse(state.observe(hasMeetingWindow: false, audioLevel: 0, at: start.addingTimeInterval(39), gracePeriod: 30))
        XCTAssertTrue(state.observe(hasMeetingWindow: false, audioLevel: 0, at: start.addingTimeInterval(40), gracePeriod: 30))
    }

    func testGoogleAuthenticationCallbackReturnsToMainActor() async {
        let expectation = expectation(description: "callback OAuth entregue no MainActor")
        let callback = NativeGoogleAuthenticationCallbackDispatcher.make { callbackURL, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(callbackURL?.absoluteString, "qapia-test:/oauthredirect?code=ok")
            XCTAssertNil(error)
            expectation.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            callback(URL(string: "qapia-test:/oauthredirect?code=ok"), nil)
        }

        await fulfillment(of: [expectation], timeout: 2)
    }

    func testMeetingDurationTextIncludesSeconds() {
        XCTAssertEqual(Meeting(recordedDuration: 0, title: "Zero").durationText, "0 min 00 s")
        XCTAssertEqual(Meeting(recordedDuration: 18, title: "Curta").durationText, "0 min 18 s")
        XCTAssertEqual(Meeting(recordedDuration: 2_765, title: "Média").durationText, "46 min 05 s")
        XCTAssertEqual(Meeting(recordedDuration: 3_723, title: "Longa").durationText, "1 h 02 min 03 s")
    }

    func testPauseAndResumePreserveElapsedTime() {
        let viewModel = MeetingViewModel(clipboard: MemoryClipboardService())
        viewModel.preview(.recording)
        let initialElapsed = viewModel.elapsed

        viewModel.pauseRecording()
        viewModel.tick()

        XCTAssertEqual(viewModel.screen, .paused)
        XCTAssertEqual(viewModel.elapsed, initialElapsed)

        viewModel.resumeRecording()
        viewModel.tick()

        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertEqual(viewModel.elapsed, initialElapsed + 1)
    }

    func testFinishMovesToProcessingWithoutStartingTranscriptionService() {
        let viewModel = MeetingViewModel(clipboard: MemoryClipboardService())
        viewModel.preview(.recording)

        viewModel.finishRecording()

        XCTAssertEqual(viewModel.screen, .processing)
        XCTAssertEqual(viewModel.selectedMeeting?.state, .preparingAudio)
        XCTAssertEqual(viewModel.selectedMeeting?.recordedDuration, 1_968)
    }

    func testCopySummaryWritesToClipboardAndShowsFeedback() {
        let clipboard = MemoryClipboardService()
        let viewModel = MeetingViewModel(clipboard: clipboard)
        viewModel.preview(.meetingDetail)

        viewModel.copySummary()

        XCTAssertEqual(clipboard.lastCopiedValue, viewModel.currentMeeting.summary)
        XCTAssertEqual(viewModel.copyFeedback, .copied)
    }

    func testCopySummaryProducesCleanPlainTextFromMarkdown() {
        let markdown = """
        ## Decisões

        - **Produto:** liberar o MVP.
          - Responsável: `Bruno`

        1. Publicar a versão
        2. Acompanhar o resultado
        """
        let meeting = Meeting(title: "Reunião", state: .completed, summary: markdown)
        let clipboard = MemoryClipboardService()
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            clipboard: clipboard,
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler()
        )
        viewModel.selectMeeting(meeting)

        viewModel.copySummary()

        XCTAssertEqual(
            clipboard.lastCopiedValue,
            """
            Decisões

            • Produto: liberar o MVP.
              • Responsável: Bruno

            1. Publicar a versão
            2. Acompanhar o resultado
            """
        )
    }

    func testPlainTextFormatterRemovesLinksQuotesAndFences() {
        let markdown = """
        > Consulte a [documentação](https://example.com).

        ```text
        conteúdo sem marcação
        ```
        """

        XCTAssertEqual(
            MarkdownPlainTextFormatter.plainText(from: markdown),
            "Consulte a documentação.\n\nconteúdo sem marcação"
        )
    }

    func testRecordingSessionCreatesSequentialSegmentsAroundPause() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureService = FakeAudioCaptureService(durations: [12, 8])
        let session = RecordingSession(
            captureService: captureService,
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let meetingID = UUID()

        try await session.start(meetingID: meetingID)
        let first = try await session.pause()
        try await session.resume()
        let segments = try await session.finish()

        XCTAssertEqual(captureService.permissionRequests, 2)
        XCTAssertEqual(captureService.startedURLs.count, 2)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(segments.map(\.sequence), [1, 2])
        XCTAssertEqual(segments.map(\.recordedDuration), [12, 8])
        XCTAssertTrue(segments[0].fileURL.lastPathComponent.hasSuffix("segment-001.m4a"))
        XCTAssertTrue(segments[1].fileURL.lastPathComponent.hasSuffix("segment-002.m4a"))
    }

    func testRecordingSessionDoesNotCreateSegmentDuringPause() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureService = FakeAudioCaptureService(durations: [4])
        let session = RecordingSession(
            captureService: captureService,
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )

        try await session.start(meetingID: UUID())
        _ = try await session.pause()

        XCTAssertEqual(captureService.startedURLs.count, 1)
        XCTAssertEqual(session.segments.count, 1)
    }

    func testElapsedClockAdvancesWhileRecording() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureService = FakeAudioCaptureService(durations: [1])
        let session = RecordingSession(
            captureService: captureService,
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let viewModel = MeetingViewModel(
            clipboard: MemoryClipboardService(),
            recordingSession: session
        )

        await viewModel.beginRecording()
        try await Task.sleep(nanoseconds: 1_100_000_000)

        XCTAssertGreaterThanOrEqual(viewModel.elapsed, 1)
        await viewModel.pauseActiveRecording()
    }

    func testViewModelMovesARealRecordingThroughPauseAndFinish() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureService = FakeAudioCaptureService(durations: [6])
        let session = RecordingSession(
            captureService: captureService,
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let transcriptionService = TranscriptionService(
            whisperService: FakeWhisperService(transcripts: [1: "Transcrição concluída."]),
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let summaryService = SummaryService(
            provider: FakeSummaryProvider(summary: "# Resumo\n\nTudo concluído."),
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let meetingStore = try SwiftDataMeetingStore(inMemory: true)
        let viewModel = MeetingViewModel(
            store: meetingStore,
            clipboard: MemoryClipboardService(),
            recordingSession: session,
            transcriptionService: transcriptionService,
            summaryService: summaryService
        )

        await viewModel.beginRecording()
        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertEqual(viewModel.selectedMeeting?.state, .recording)

        captureService.emitLevel(AudioLevelSample(microphone: 0.64, system: 0.28))
        await Task.yield()
        XCTAssertEqual(viewModel.audioLevel, 0.64, accuracy: 0.001)

        await viewModel.pauseActiveRecording()
        XCTAssertEqual(viewModel.screen, .paused)
        XCTAssertEqual(viewModel.elapsed, 6)
        XCTAssertEqual(viewModel.audioLevel, 0)

        await viewModel.finishActiveRecording()

        await waitUntil {
            viewModel.selectedMeeting?.state == .completed
        }
        XCTAssertEqual(viewModel.screen, .meetingDetail)
        XCTAssertEqual(viewModel.selectedMeeting?.state, .completed)
        XCTAssertEqual(viewModel.selectedMeeting?.recordingSegments.count, 1)
        XCTAssertEqual(viewModel.selectedMeeting?.transcript, "Transcrição concluída.")
        XCTAssertEqual(viewModel.selectedMeeting?.summary, "# Resumo\n\nTudo concluído.")
        XCTAssertEqual(viewModel.detailTab, .summary)

        let persisted = try XCTUnwrap(meetingStore.loadMeetings().first)
        XCTAssertEqual(persisted.state, .completed)
        XCTAssertEqual(persisted.recordingSegments.count, 1)
        XCTAssertEqual(persisted.transcript, "Transcrição concluída.")
        XCTAssertEqual(persisted.summary, "# Resumo\n\nTudo concluído.")
    }

    func testAudioLevelAnalyzerNormalizesAndSmoothsSafely() {
        XCTAssertEqual(AudioLevelAnalyzer.rootMeanSquare(of: [1, -1, 1, -1]), 1, accuracy: 0.001)
        XCTAssertEqual(AudioLevelAnalyzer.normalizedLevel(fromRMS: 0), 0)
        XCTAssertEqual(AudioLevelAnalyzer.normalizedLevel(fromRMS: 0.001), 0)
        XCTAssertGreaterThan(AudioLevelAnalyzer.normalizedLevel(fromRMS: 0.1), 0.5)
        XCTAssertEqual(AudioLevelAnalyzer.normalizedLevel(fromRMS: .nan), 0)

        let attack = AudioLevelAnalyzer.smoothed(previous: 0, incoming: 1)
        let release = AudioLevelAnalyzer.smoothed(previous: 1, incoming: 0)
        XCTAssertGreaterThan(attack, 1 - release)

        let sample = AudioLevelSample(microphone: 2, system: -.infinity)
        XCTAssertEqual(sample.microphone, 1)
        XCTAssertEqual(sample.system, 0)
        XCTAssertEqual(sample.combined, 1)
    }

    func testSwiftDataStorePersistsCompleteMeetingAcrossReopening() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let storeURL = rootURL.appendingPathComponent("QAPia.store")
        let meetingID = UUID()
        let audioURL = rootURL.appendingPathComponent("segment-001.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let meeting = Meeting(
            id: meetingID,
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_777_000_120),
            recordedDuration: 120,
            title: "Reunião persistida",
            state: .completed,
            templateId: SummaryTemplate.custom.id,
            customTemplateStructure: "Contexto; Decisões",
            transcript: "Transcrição persistida.",
            summary: "# Resumo persistido",
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: audioURL,
                    recordedDuration: 120,
                    createdAt: Date(timeIntervalSince1970: 1_777_000_000)
                )
            ]
        )

        do {
            let store = try SwiftDataMeetingStore(storeURL: storeURL)
            try store.save(meeting)
        }

        let reopenedStore = try SwiftDataMeetingStore(storeURL: storeURL)
        let loaded = try XCTUnwrap(reopenedStore.loadMeetings().first)

        XCTAssertEqual(loaded.id, meeting.id)
        XCTAssertEqual(loaded.title, meeting.title)
        XCTAssertEqual(loaded.state, .completed)
        XCTAssertEqual(loaded.recordedDuration, 120)
        XCTAssertEqual(loaded.templateId, SummaryTemplate.custom.id)
        XCTAssertEqual(loaded.customTemplateStructure, "Contexto; Decisões")
        XCTAssertEqual(loaded.transcript, "Transcrição persistida.")
        XCTAssertEqual(loaded.summary, "# Resumo persistido")
        XCTAssertEqual(loaded.recordingSegments.count, 1)
        XCTAssertEqual(loaded.recordingSegments.first?.fileURL, audioURL)
        XCTAssertFalse(loaded.hasUnavailableAudio)
    }

    func testSwiftDataStorePreservesMeetingWhenAudioPathIsMissing() throws {
        let store = try SwiftDataMeetingStore(inMemory: true)
        let meetingID = UUID()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("segment-001.m4a")
        let meeting = Meeting(
            id: meetingID,
            recordedDuration: 30,
            title: "Áudio indisponível",
            state: .completed,
            transcript: "A transcrição continua disponível.",
            summary: "# Resumo preservado",
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: missingURL,
                    recordedDuration: 30
                )
            ]
        )

        try store.save(meeting)
        let loaded = try XCTUnwrap(store.loadMeetings().first)

        XCTAssertEqual(loaded.transcript, meeting.transcript)
        XCTAssertEqual(loaded.summary, meeting.summary)
        XCTAssertEqual(loaded.recordingSegments.count, 1)
        XCTAssertTrue(loaded.hasUnavailableAudio)
        XCTAssertEqual(loaded.missingRecordingSegmentCount, 1)
    }

    func testSwiftDataStorePreservesInterruptedProcessingForAutomaticResume() throws {
        let store = try SwiftDataMeetingStore(inMemory: true)
        let meeting = Meeting(
            title: "Processamento interrompido",
            state: .transcribing,
            transcript: ""
        )

        try store.save(meeting)
        let recovered = try XCTUnwrap(store.loadMeetings().first)

        XCTAssertEqual(recovered.state, .transcribing)
        XCTAssertEqual(recovered.id, meeting.id)
    }

    func testDeletingMeetingRemovesHistoryAndLocalFiles() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let segmentURL = try fileStore.makeSegmentURL(meetingID: meetingID, sequence: 1)
        try Data("audio".utf8).write(to: segmentURL)
        try fileStore.writeTranscript("Transcrição", meetingID: meetingID)
        try fileStore.writeSummary("# Resumo", meetingID: meetingID)
        let meeting = Meeting(
            id: meetingID,
            recordedDuration: 12,
            title: "Reunião descartável",
            state: .completed,
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: segmentURL,
                    recordedDuration: 12
                )
            ]
        )
        let store = MockMeetingStore(meetings: [meeting])
        let viewModel = MeetingViewModel(
            store: store,
            clipboard: MemoryClipboardService(),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore
        )
        viewModel.selectMeeting(meeting)

        viewModel.deleteMeeting(meeting)

        XCTAssertTrue(viewModel.meetings.isEmpty)
        XCTAssertNil(viewModel.selectedMeetingID)
        XCTAssertEqual(viewModel.screen, .empty)
        XCTAssertTrue(try store.loadMeetings().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent(meetingID.uuidString).path
            )
        )
    }

    func testSwiftDataStoreDeletesMeetingPersistently() throws {
        let store = try SwiftDataMeetingStore(inMemory: true)
        let meeting = Meeting(title: "Excluir do banco", state: .completed)
        try store.save(meeting)

        try store.delete(id: meeting.id)

        XCTAssertTrue(try store.loadMeetings().isEmpty)
    }

    func testRecordingSessionAllowsRetryAfterStartFailure() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureService = RetryableFakeAudioCaptureService()
        let session = RecordingSession(
            captureService: captureService,
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let meetingID = UUID()

        await XCTAssertThrowsErrorAsync {
            try await session.start(meetingID: meetingID)
        }
        try await session.start(meetingID: meetingID)

        XCTAssertEqual(captureService.startAttempts, 2)
    }

    func testTranscriptionCombinesSegmentsInSequenceAndPersistsTranscript() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let first = RecordingSegment(
            meetingID: meetingID,
            sequence: 1,
            fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
            recordedDuration: 10
        )
        let second = RecordingSegment(
            meetingID: meetingID,
            sequence: 2,
            fileURL: rootURL.appendingPathComponent("segment-002.m4a"),
            recordedDuration: 12
        )
        let service = TranscriptionService(
            whisperService: FakeWhisperService(transcripts: [
                1: "Primeiro segmento.",
                2: "Segundo segmento."
            ]),
            fileStore: fileStore
        )

        let transcript = try await service.transcribe(meetingID: meetingID, segments: [second, first])

        XCTAssertEqual(transcript, "Primeiro segmento.\n\nSegundo segmento.")
        XCTAssertEqual(
            try String(contentsOf: fileStore.transcriptURL(meetingID: meetingID), encoding: .utf8),
            transcript
        )
    }

    func testTranscriptionFailureDoesNotWritePartialTranscript() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let segment = RecordingSegment(
            meetingID: meetingID,
            sequence: 1,
            fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
            recordedDuration: 10
        )
        let service = TranscriptionService(
            whisperService: FakeWhisperService(transcripts: [:], error: .emptyTranscript),
            fileStore: fileStore
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await service.transcribe(meetingID: meetingID, segments: [segment])
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try fileStore.transcriptURL(meetingID: meetingID).path))
    }

    func testSummaryServicePersistsMarkdown() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let expected = "# Resumo executivo\n\n- Decisão confirmada"
        let service = SummaryService(
            provider: FakeSummaryProvider(summary: expected),
            fileStore: fileStore
        )

        let summary = try await service.generateSummary(
            meetingID: meetingID,
            transcript: "A equipe confirmou a decisão.",
            template: .general
        )

        XCTAssertEqual(summary, expected)
        XCTAssertEqual(
            try String(contentsOf: fileStore.summaryURL(meetingID: meetingID), encoding: .utf8),
            expected
        )
    }

    func testSummaryTemplatesExposeRequiredStructures() {
        XCTAssertEqual(
            SummaryTemplate.allCases.map(\.displayName),
            ["Reunião Geral", "Product Discovery", "Refinamento", "Daily", "Personalizado"]
        )
        XCTAssertTrue(SummaryTemplate.general.sections.contains("Responsáveis"))
        XCTAssertTrue(SummaryTemplate.productDiscovery.sections.contains("Feature requests"))
        XCTAssertTrue(SummaryTemplate.refinement.sections.contains("Regras de negócio"))
        XCTAssertTrue(SummaryTemplate.daily.sections.contains("Bloqueios"))
        XCTAssertEqual(
            SummaryTemplate.custom.personalized(with: "Objetivos; Riscos; Ações").sections,
            ["Objetivos", "Riscos", "Ações"]
        )
    }

    func testTemplateStorePersistsBuiltInEditsAndCustomTemplates() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("templates.json")
        let store = LocalSummaryTemplateStore(fileURL: fileURL)
        let editedGeneral = SummaryTemplate(
            id: SummaryTemplate.general.id,
            displayName: "Reunião Executiva",
            instructions: "Destaque somente decisões confirmadas.",
            sections: ["Síntese", "Decisões"],
            isBuiltIn: true
        )
        let custom = SummaryTemplate(
            id: "user-retro",
            displayName: "Retrospectiva",
            instructions: "Organize aprendizados do ciclo.",
            sections: ["Funcionou", "Melhorar", "Ações"]
        )

        try store.saveTemplates([editedGeneral, custom])
        let loaded = try LocalSummaryTemplateStore(fileURL: fileURL).loadTemplates()

        XCTAssertEqual(loaded.first(where: { $0.id == "general" })?.displayName, "Reunião Executiva")
        XCTAssertEqual(loaded.first(where: { $0.id == "general" })?.sections, ["Síntese", "Decisões"])
        XCTAssertEqual(loaded.first(where: { $0.id == "user-retro" })?.instructions, "Organize aprendizados do ciclo.")
        XCTAssertTrue(loaded.contains(where: { $0.id == SummaryTemplate.daily.id }))
    }

    func testTemplateEditorCreatesDuplicatesAndDeletesUserTemplates() {
        let templateStore = MemorySummaryTemplateStore()
        let viewModel = MeetingViewModel(
            templateStore: templateStore,
            clipboard: MemoryClipboardService()
        )

        viewModel.showSettings()
        viewModel.beginCreatingTemplate()
        viewModel.templateNameDraft = "Retrospectiva"
        viewModel.templateInstructionsDraft = "Destaque aprendizados e ações."
        viewModel.templateSectionsDraft = "Funcionou\nMelhorar\nAções"
        viewModel.saveTemplateDraft()

        XCTAssertEqual(viewModel.templates.count, SummaryTemplate.allCases.count + 1)
        XCTAssertEqual(viewModel.editingTemplate?.displayName, "Retrospectiva")
        XCTAssertTrue(viewModel.canDeleteEditingTemplate)

        viewModel.duplicateEditingTemplate()
        XCTAssertEqual(viewModel.templates.count, SummaryTemplate.allCases.count + 2)
        XCTAssertTrue(viewModel.editingTemplate?.displayName.contains("cópia") == true)

        viewModel.deleteEditingTemplate()
        XCTAssertEqual(viewModel.templates.count, SummaryTemplate.allCases.count + 1)
        XCTAssertEqual(templateStore.templates.count, SummaryTemplate.allCases.count + 1)
    }

    func testTemplateEditorRejectsInvalidFields() {
        let templateStore = MemorySummaryTemplateStore()
        let viewModel = MeetingViewModel(
            templateStore: templateStore,
            clipboard: MemoryClipboardService()
        )

        viewModel.beginCreatingTemplate()
        viewModel.templateNameDraft = ""
        viewModel.templateInstructionsDraft = ""
        viewModel.templateSectionsDraft = ""
        viewModel.saveTemplateDraft()

        XCTAssertEqual(viewModel.templates.count, SummaryTemplate.allCases.count)
        XCTAssertFalse(viewModel.templateEditorSaved)
        XCTAssertEqual(viewModel.templateEditorMessage, "Informe um nome para o template.")
    }

    func testTemplateSnapshotPreservesInstructionsAndSections() {
        let original = SummaryTemplate(
            id: "user-planning",
            displayName: "Planejamento",
            instructions: "Priorize compromissos confirmados.",
            sections: ["Objetivos", "Responsáveis"]
        )
        let edited = SummaryTemplate(
            id: original.id,
            displayName: original.displayName,
            instructions: "Nova orientação.",
            sections: ["Nova estrutura"]
        )

        let restored = edited.applyingSnapshot(original.snapshotValue)

        XCTAssertEqual(restored.instructions, original.instructions)
        XCTAssertEqual(restored.sections, original.sections)
    }

    func testSummaryPromptRestrictsHallucinationsAndUsesTemplateSections() {
        let prompt = SummaryPrompt.user(
            transcript: "Foi discutida a entrega.",
            template: .refinement
        )

        XCTAssertTrue(SummaryPrompt.system.contains("Use exclusivamente"))
        XCTAssertTrue(SummaryPrompt.system.contains("Não invente"))
        XCTAssertTrue(SummaryPrompt.system.contains("Não informado na transcrição"))
        XCTAssertTrue(prompt.contains("## Requisitos"))
        XCTAssertTrue(prompt.contains("## Próximos passos"))
        XCTAssertTrue(prompt.contains(SummaryTemplate.refinement.instructions))
        XCTAssertTrue(prompt.contains("<transcricao>"))
    }

    func testExtractiveSummaryUsesTranscriptFactsAndMarksAbsentSections() async throws {
        let provider = ExtractiveSummaryProvider()
        let summary = try await provider.generateSummary(
            transcript: "A equipe aprovou o novo cronograma. Bruno vai enviar a proposta na sexta-feira. Há uma dependência do contrato.",
            template: .general
        )

        XCTAssertTrue(summary.contains("## Decisões\n\n- A equipe aprovou o novo cronograma"))
        XCTAssertTrue(summary.contains("## Pendências\n\n- Há uma dependência do contrato"))
        XCTAssertTrue(summary.contains("## Próximos passos\n\n- Bruno vai enviar a proposta na sexta-feira"))
        XCTAssertTrue(summary.contains("## Responsáveis\n\n- Bruno vai enviar a proposta na sexta-feira"))
        XCTAssertTrue(summary.contains("## Prazos\n\n- Bruno vai enviar a proposta na sexta-feira"))
        XCTAssertTrue(summary.contains("## Assuntos discutidos\n\n- A equipe aprovou o novo cronograma"))

        let refinement = try await provider.generateSummary(
            transcript: "A equipe aprovou o novo cronograma.",
            template: .refinement
        )
        XCTAssertTrue(refinement.contains("## Riscos\n\nNão informado na transcrição"))
    }

    func testOnDeviceSummaryRejectsAnEmptyTranscript() async throws {
        let provider = OnDeviceSummaryProvider()

        do {
            _ = try await provider.generateSummary(transcript: "   ", template: .general)
            XCTFail("Era esperado um erro de transcrição vazia.")
        } catch let error as SummaryProviderError {
            XCTAssertEqual(error, .emptyTranscript)
        }
    }

    func testSummaryFailurePreservesTranscriptAndRecordingSegments() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let session = RecordingSession(
            captureService: FakeAudioCaptureService(durations: [9]),
            fileStore: fileStore
        )
        let viewModel = MeetingViewModel(
            clipboard: MemoryClipboardService(),
            recordingSession: session,
            transcriptionService: TranscriptionService(
                whisperService: FakeWhisperService(transcripts: [1: "Transcrição preservada."]),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(error: .generationFailed("falha simulada")),
                fileStore: fileStore
            )
        )

        await viewModel.beginRecording()
        await viewModel.finishActiveRecording()

        await waitUntil {
            viewModel.selectedMeeting?.state == .failed
        }

        XCTAssertEqual(viewModel.selectedMeeting?.state, .failed)
        XCTAssertEqual(viewModel.selectedMeeting?.transcript, "Transcrição preservada.")
        XCTAssertEqual(viewModel.selectedMeeting?.recordingSegments.count, 1)
        XCTAssertEqual(viewModel.detailTab, .transcript)
        XCTAssertEqual(viewModel.errorTitle, "Não foi possível gerar o resumo")
    }

    func testWhisperCppTranscribesMultitrackFixtureWhenProvided() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["QAPIA_TRANSCRIPTION_FIXTURE"] else {
            throw XCTSkip("Defina QAPIA_TRANSCRIPTION_FIXTURE para validar um M4A real.")
        }

        let meetingID = UUID()
        let segment = RecordingSegment(
            meetingID: meetingID,
            sequence: 1,
            fileURL: URL(fileURLWithPath: fixturePath),
            recordedDuration: 0
        )

        let transcript = try await WhisperCppService().transcribe(segment: segment)

        XCTAssertFalse(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testCalendarEventSuggestsRecordingTenMinutesBeforeStart() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let event = CalendarEvent(
            id: "calendar-1",
            title: "Planejamento trimestral",
            start: start,
            end: start.addingTimeInterval(3_600)
        )

        XCTAssertFalse(event.isRecordingSuggestion(at: start.addingTimeInterval(-601)))
        XCTAssertTrue(event.isRecordingSuggestion(at: start.addingTimeInterval(-600)))
        XCTAssertTrue(event.isRecordingSuggestion(at: start.addingTimeInterval(30)))
        XCTAssertFalse(event.isRecordingSuggestion(at: event.end))
    }

    func testParticipantPreviewShowsFourEntriesAndRemainingCount() {
        let meeting = Meeting(
            title: "Reunião com participantes",
            participants: [
                "ana@example.com",
                "bruno@example.com",
                "carla@example.com",
                "diego@example.com",
                "eduarda@example.com",
                "fabio@example.com"
            ]
        )

        XCTAssertEqual(
            meeting.participantPreview(),
            "ana@example.com, bruno@example.com, carla@example.com, diego@example.com  +2"
        )
    }

    func testCalendarReminderContentIncludesCTAAndCalendarEventID() {
        let event = CalendarEvent(
            id: "calendar-reminder-1",
            title: "Revisão semanal",
            start: Date().addingTimeInterval(600),
            end: Date().addingTimeInterval(2_400)
        )

        let content = CalendarReminderScheduler.notificationContent(for: event)

        XCTAssertEqual(content.title, "Reunião em 10 minutos")
        XCTAssertEqual(content.categoryIdentifier, CalendarReminderScheduler.categoryIdentifier)
        XCTAssertEqual(content.userInfo["calendarEventID"] as? String, event.id)
        XCTAssertTrue(content.body.contains("Iniciar gravação"))
    }

    func testCalendarReminderStartsTheMatchingEvent() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = RecordingSession(
            captureService: FakeAudioCaptureService(durations: [2]),
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let event = CalendarEvent(
            id: "notification-target",
            title: "Reunião iniciada pelo lembrete",
            start: Date().addingTimeInterval(600),
            end: Date().addingTimeInterval(2_400),
            participants: [
                CalendarParticipant(email: "ana@example.com", displayName: "Ana")
            ]
        )
        let calendarService = FakeGoogleCalendarService()
        calendarService.account = GoogleCalendarAccount(email: "teste@gmail.com")
        calendarService.events = [event]
        let viewModel = MeetingViewModel(
            store: EmptyMeetingStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: session,
            calendarService: calendarService,
            reminderScheduler: FakeReminderScheduler()
        )

        for _ in 0..<50 where viewModel.calendarEvents.isEmpty {
            await Task.yield()
        }
        viewModel.handleCalendarReminder(eventID: event.id)
        for _ in 0..<50 where viewModel.screen != .recording {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertEqual(viewModel.selectedMeeting?.calendarEventID, event.id)
        XCTAssertEqual(viewModel.selectedMeeting?.title, event.title)
        await viewModel.pauseActiveRecording()
    }

    func testCalendarAgendaShowsOnlyFiveRemainingMeetingsAndSupportsFutureDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 26))!
        let now = today.addingTimeInterval(12 * 3_600)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let ended = CalendarEvent(
            id: "ended",
            title: "Já terminou",
            start: today.addingTimeInterval(9 * 3_600),
            end: today.addingTimeInterval(10 * 3_600)
        )
        let remaining = (0..<7).map { index in
            CalendarEvent(
                id: "remaining-\(index)",
                title: "Reunião \(index)",
                start: today.addingTimeInterval(TimeInterval(11 + index) * 3_600),
                end: today.addingTimeInterval(TimeInterval(12 + index) * 3_600 + 1)
            )
        }
        let future = CalendarEvent(
            id: "tomorrow",
            title: "Agenda futura",
            start: tomorrow.addingTimeInterval(9 * 3_600),
            end: tomorrow.addingTimeInterval(10 * 3_600)
        )

        let todayEvents = CalendarAgenda.events(
            from: [future, ended] + Array(remaining.reversed()),
            on: today,
            relativeTo: now,
            calendar: calendar
        )
        let tomorrowEvents = CalendarAgenda.events(
            from: [future, ended] + remaining,
            on: tomorrow,
            relativeTo: now,
            calendar: calendar
        )

        XCTAssertEqual(todayEvents.map(\.id), ["remaining-0", "remaining-1", "remaining-2", "remaining-3", "remaining-4"])
        XCTAssertEqual(tomorrowEvents.map(\.id), ["tomorrow"])
    }

    func testCalendarRecordingUsesEventTitleAndParticipants() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = RecordingSession(
            captureService: FakeAudioCaptureService(durations: [3]),
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let viewModel = MeetingViewModel(
            store: EmptyMeetingStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: session,
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler()
        )
        let event = CalendarEvent(
            id: "calendar-42",
            title: "Revisão do lançamento",
            start: Date(),
            end: Date().addingTimeInterval(1_800),
            participants: [
                CalendarParticipant(email: "eu@example.com", displayName: "Eu", isCurrentUser: true),
                CalendarParticipant(email: "ana@example.com", displayName: "Ana")
            ]
        )

        await viewModel.beginRecording(calendarEvent: event)

        XCTAssertEqual(viewModel.selectedMeeting?.title, "Revisão do lançamento")
        XCTAssertEqual(viewModel.selectedMeeting?.participants, ["Ana"])
        XCTAssertEqual(viewModel.selectedMeeting?.calendarEventID, "calendar-42")
        await viewModel.pauseActiveRecording()
    }

    func testMeetingMetadataCanBeEditedAndSearchedByParticipantOrContext() {
        let meeting = Meeting(
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            title: "Status antigo",
            state: .completed,
            transcript: "Discutimos a estratégia de lançamento.",
            summary: "Plano aprovado.",
            participants: ["Ana Souza"]
        )
        let store = MockMeetingStore(meetings: [meeting])
        let viewModel = MeetingViewModel(
            store: store,
            clipboard: MemoryClipboardService(),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler()
        )
        viewModel.selectMeeting(meeting)
        viewModel.meetingTitleDraft = "Revisão do lançamento"
        viewModel.meetingParticipantsDraft = "Ana Souza, Bruno Lima; Ana Souza"
        viewModel.saveMeetingMetadata()

        XCTAssertEqual(viewModel.selectedMeeting?.title, "Revisão do lançamento")
        XCTAssertEqual(viewModel.selectedMeeting?.participants, ["Ana Souza", "Bruno Lima"])

        viewModel.searchText = "bruno"
        XCTAssertEqual(viewModel.filteredMeetings.map(\.id), [meeting.id])
        viewModel.searchText = "estrategia"
        XCTAssertEqual(viewModel.filteredMeetings.map(\.id), [meeting.id])
        viewModel.searchText = "inexistente"
        XCTAssertTrue(viewModel.filteredMeetings.isEmpty)
    }

    func testProcessingContinuesWhenUserNavigatesAway() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let session = RecordingSession(
            captureService: FakeAudioCaptureService(durations: [4]),
            fileStore: fileStore
        )
        let viewModel = MeetingViewModel(
            store: try SwiftDataMeetingStore(inMemory: true),
            clipboard: MemoryClipboardService(),
            recordingSession: session,
            transcriptionService: TranscriptionService(
                whisperService: DelayedFakeWhisperService(transcript: "Transcrição em segundo plano."),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo\n\nProcessamento preservado."),
                fileStore: fileStore
            )
        )

        await viewModel.beginRecording()
        let meetingID = try XCTUnwrap(viewModel.selectedMeeting?.id)
        await viewModel.finishActiveRecording()
        viewModel.showSettings()

        XCTAssertEqual(viewModel.screen, .settings)
        await waitUntil {
            viewModel.meetings.first(where: { $0.id == meetingID })?.state == .completed
        }

        let completed = try XCTUnwrap(viewModel.meetings.first(where: { $0.id == meetingID }))
        XCTAssertEqual(viewModel.screen, .settings)
        XCTAssertEqual(completed.transcript, "Transcrição em segundo plano.")
        XCTAssertEqual(completed.summary, "# Resumo\n\nProcessamento preservado.")
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
private final class FakeAudioCaptureService: AudioCaptureService, AudioLevelProviding {
    private let durations: [TimeInterval]
    private var durationIndex = 0
    private var activeURL: URL?
    private(set) var permissionRequests = 0
    private(set) var startedURLs: [URL] = []
    private var audioLevelHandler: (@Sendable (AudioLevelSample) -> Void)?

    init(durations: [TimeInterval]) {
        self.durations = durations
    }

    func requestPermissions() async throws {
        permissionRequests += 1
    }

    func setAudioLevelHandler(_ handler: (@Sendable (AudioLevelSample) -> Void)?) {
        audioLevelHandler = handler
    }

    func emitLevel(_ sample: AudioLevelSample) {
        audioLevelHandler?(sample)
    }

    func startSegment(at fileURL: URL) async throws {
        activeURL = fileURL
        startedURLs.append(fileURL)
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let activeURL else { throw RecordingError.noActiveRecording }
        defer { self.activeURL = nil }
        let duration = durations[durationIndex]
        durationIndex += 1
        return CapturedAudio(fileURL: activeURL, duration: duration)
    }
}

@MainActor
private final class RetryableFakeAudioCaptureService: AudioCaptureService {
    private(set) var startAttempts = 0

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        startAttempts += 1
        if startAttempts == 1 {
            throw RecordingError.captureFailed("Falha temporária de permissão.")
        }
    }

    func stopSegment() async throws -> CapturedAudio {
        throw RecordingError.noActiveRecording
    }
}

private struct FakeWhisperService: WhisperService {
    let transcripts: [Int: String]
    let error: WhisperError?

    init(transcripts: [Int: String], error: WhisperError? = nil) {
        self.transcripts = transcripts
        self.error = error
    }

    func transcribe(segment: RecordingSegment) async throws -> String {
        if let error { throw error }
        return transcripts[segment.sequence] ?? ""
    }
}

private struct DelayedFakeWhisperService: WhisperService {
    let transcript: String

    func transcribe(segment: RecordingSegment) async throws -> String {
        try await Task.sleep(nanoseconds: 150_000_000)
        return transcript
    }
}

@MainActor
private final class FakeLocalResourcePreparer: LocalResourcePreparing, @unchecked Sendable {
    private(set) var prepareCountValue = 0

    func prepare() async throws {
        prepareCountValue += 1
    }
}

private struct FakeSummaryProvider: SummaryProvider {
    let summary: String?
    let error: SummaryProviderError?

    init(summary: String) {
        self.summary = summary
        self.error = nil
    }

    init(error: SummaryProviderError) {
        self.summary = nil
        self.error = error
    }

    func generateSummary(transcript: String, template: SummaryTemplate) async throws -> String {
        if let error { throw error }
        return summary ?? ""
    }
}

@MainActor
private final class FakeGoogleCalendarService: GoogleCalendarServing {
    var isConfigured = true
    var account: GoogleCalendarAccount?
    var events: [CalendarEvent] = []

    func restoreAccount() async -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount {
        let connected = GoogleCalendarAccount(email: "teste@gmail.com")
        account = connected
        return connected
    }
    func disconnect() async { account = nil }
    func upcomingEvents(from: Date, through: Date) async throws -> [CalendarEvent] { events }
}

@MainActor
private final class FakeReminderScheduler: CalendarReminderScheduling {
    private(set) var scheduledEvents: [CalendarEvent] = []
    func scheduleReminders(for events: [CalendarEvent]) async {
        scheduledEvents = events
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Era esperado um erro.", file: file, line: line)
    } catch {}
}
