import XCTest
@testable import QapiaCore

@MainActor
final class TemplateSelectionRegressionTests: XCTestCase {
    func testHistoricalHiringMeetingDoesNotChangeTemplateOfNextRecording() async throws {
        let historicalMeeting = Meeting(
            title: "Entrevista anterior",
            state: .completed,
            templateId: SummaryTemplate.hiring.id,
            customTemplateStructure: SummaryTemplate.hiring.snapshotValue,
            transcript: "A pessoa candidata apresentou sua experiência.",
            summary: "## Trajetória profissional\n\nExperiência apresentada."
        )
        let fixture = makeRecordingFixture(meetings: [historicalMeeting])

        fixture.viewModel.selectMeeting(historicalMeeting)
        XCTAssertEqual(fixture.viewModel.selectedTemplate.id, SummaryTemplate.hiring.id)

        fixture.viewModel.showRecordings()
        await fixture.viewModel.beginRecording()

        let newMeeting = try XCTUnwrap(fixture.viewModel.selectedMeeting)
        XCTAssertNotEqual(newMeeting.id, historicalMeeting.id)
        XCTAssertEqual(newMeeting.templateId, SummaryTemplate.standardMeeting.id)
        let persistedTemplate = SummaryTemplate.standardMeeting.applyingSnapshot(
            newMeeting.customTemplateStructure
        )
        XCTAssertEqual(
            persistedTemplate.instructions,
            SummaryTemplate.standardMeeting.instructions
        )
        XCTAssertEqual(persistedTemplate.sections, SummaryTemplate.standardMeeting.sections)
        XCTAssertEqual(
            try fixture.store.loadMeetings().first(where: { $0.id == newMeeting.id })?.templateId,
            SummaryTemplate.standardMeeting.id
        )
    }

    func testExplicitHomeTemplateSelectionIsPersistedByNewRecording() async throws {
        let fixture = makeRecordingFixture()
        fixture.viewModel.newMeetingTemplate = .projectSync

        await fixture.viewModel.beginRecording()

        let newMeeting = try XCTUnwrap(fixture.viewModel.selectedMeeting)
        XCTAssertEqual(newMeeting.templateId, SummaryTemplate.projectSync.id)
        let persistedTemplate = SummaryTemplate.projectSync.applyingSnapshot(
            newMeeting.customTemplateStructure
        )
        XCTAssertEqual(
            persistedTemplate.instructions,
            SummaryTemplate.projectSync.instructions
        )
        XCTAssertEqual(persistedTemplate.sections, SummaryTemplate.projectSync.sections)
        XCTAssertEqual(
            try fixture.store.loadMeetings().first(where: { $0.id == newMeeting.id })?.templateId,
            SummaryTemplate.projectSync.id
        )
    }

    func testDetailSelectionAndSummaryRegenerationStayIndependentFromHomeSelection() async throws {
        let meeting = Meeting(
            title: "Reunião existente",
            state: .completed,
            templateId: SummaryTemplate.hiring.id,
            customTemplateStructure: SummaryTemplate.hiring.snapshotValue,
            transcript: "Marina informou que concluirá a revisão na sexta-feira.",
            summary: "## Trajetória profissional\n\nResumo anterior."
        )
        let store = MockMeetingStore(meetings: [meeting])
        let provider = TemplateSelectionSummaryProvider()
        let fileStore = LocalMeetingFileStore(rootURL: temporaryRoot())
        let viewModel = MeetingViewModel(
            store: store,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            summaryService: SummaryService(provider: provider, fileStore: fileStore),
            fileStore: fileStore
        )
        viewModel.newMeetingTemplate = .projectSync

        viewModel.selectMeeting(meeting)

        XCTAssertEqual(viewModel.selectedTemplate.id, SummaryTemplate.hiring.id)
        XCTAssertEqual(viewModel.newMeetingTemplate.id, SummaryTemplate.projectSync.id)

        viewModel.selectSummaryTemplate(.oneOnOne)
        await waitUntil {
            viewModel.meetings.first?.summary.contains("Resumo regenerado.") == true
        }

        let regeneratedTemplateID = await provider.lastTemplateID()
        XCTAssertEqual(viewModel.meetings.first?.templateId, SummaryTemplate.oneOnOne.id)
        XCTAssertEqual(viewModel.newMeetingTemplate.id, SummaryTemplate.projectSync.id)
        XCTAssertEqual(regeneratedTemplateID, SummaryTemplate.oneOnOne.id)
    }

    func testSelectingCompletedMeetingDoesNotRegenerateSummary() async throws {
        let meeting = Meeting(
            title: "Reunião existente",
            state: .completed,
            templateId: SummaryTemplate.hiring.id,
            customTemplateStructure: SummaryTemplate.hiring.snapshotValue,
            transcript: "A transcrição já está pronta.",
            summary: "Resumo preservado."
        )
        let provider = TemplateSelectionSummaryProvider()
        let fileStore = LocalMeetingFileStore(rootURL: temporaryRoot())
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            summaryService: SummaryService(provider: provider, fileStore: fileStore),
            fileStore: fileStore
        )

        viewModel.selectMeeting(meeting)
        await Task.yield()

        XCTAssertEqual(viewModel.selectedTemplate.id, SummaryTemplate.hiring.id)
        XCTAssertEqual(viewModel.currentMeeting.summary, "Resumo preservado.")
        let generationCount = await provider.callCount()
        XCTAssertEqual(generationCount, 0)
    }

    func testProcessingPresentationPrioritizesRetranscriptionState() async {
        let retranscribingMeeting = Meeting(
            title: "Reprocessando áudio",
            state: .transcribing,
            templateId: SummaryTemplate.standardMeeting.id,
            customTemplateStructure: SummaryTemplate.standardMeeting.snapshotValue,
            transcript: "Transcrição anterior preservada.",
            summary: "Resumo anterior preservado."
        )
        let retranscriptionViewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [retranscribingMeeting]),
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService()
        )

        retranscriptionViewModel.selectMeeting(retranscribingMeeting)

        XCTAssertEqual(retranscriptionViewModel.screen, .processing)
        XCTAssertFalse(retranscriptionViewModel.isCurrentMeetingSummarizing)

        let completedMeeting = Meeting(
            title: "Resumo automático",
            state: .completed,
            templateId: SummaryTemplate.standardMeeting.id,
            customTemplateStructure: SummaryTemplate.standardMeeting.snapshotValue,
            transcript: "Transcrição concluída.",
            summary: "Resumo anterior."
        )
        let provider = TemplateSelectionSummaryProvider()
        let fileStore = LocalMeetingFileStore(rootURL: temporaryRoot())
        let summaryViewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [completedMeeting]),
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            summaryService: SummaryService(provider: provider, fileStore: fileStore),
            fileStore: fileStore
        )
        summaryViewModel.selectMeeting(completedMeeting)

        summaryViewModel.selectSummaryTemplate(.projectSync)

        XCTAssertEqual(summaryViewModel.screen, .processing)
        XCTAssertTrue(summaryViewModel.isCurrentMeetingSummarizing)
        await waitUntil {
            summaryViewModel.currentMeeting.state == .completed
        }
    }

    func testTemplateChangeRollsBackWhenPersistenceFails() async throws {
        let meeting = Meeting(
            title: "Reunião protegida",
            state: .completed,
            templateId: SummaryTemplate.hiring.id,
            customTemplateStructure: SummaryTemplate.hiring.snapshotValue,
            transcript: "Transcrição disponível.",
            summary: "Resumo preservado."
        )
        let store = FailingTemplateChangeMeetingStore(meeting: meeting)
        let provider = TemplateSelectionSummaryProvider()
        let fileStore = LocalMeetingFileStore(rootURL: temporaryRoot())
        let viewModel = MeetingViewModel(
            store: store,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            summaryService: SummaryService(provider: provider, fileStore: fileStore),
            fileStore: fileStore
        )
        viewModel.selectMeeting(meeting)

        viewModel.selectSummaryTemplate(.oneOnOne)

        XCTAssertEqual(viewModel.selectedTemplate.id, SummaryTemplate.hiring.id)
        XCTAssertEqual(viewModel.currentMeeting.templateId, SummaryTemplate.hiring.id)
        XCTAssertEqual(
            viewModel.currentMeeting.customTemplateStructure,
            SummaryTemplate.hiring.snapshotValue
        )
        XCTAssertEqual(try store.loadMeetings().first?.templateId, SummaryTemplate.hiring.id)
        XCTAssertEqual(viewModel.screen, .meetingDetail)
        let generationCount = await provider.callCount()
        XCTAssertEqual(generationCount, 0)
    }

    func testRapidTemplateChangesDiscardObsoleteSummary() async throws {
        let meeting = Meeting(
            title: "Planejamento",
            state: .completed,
            templateId: SummaryTemplate.standardMeeting.id,
            customTemplateStructure: SummaryTemplate.standardMeeting.snapshotValue,
            transcript: "O time definiu os próximos passos.",
            summary: "Resumo original."
        )
        let store = MockMeetingStore(meetings: [meeting])
        let provider = RacingTemplateSummaryProvider()
        let fileStore = LocalMeetingFileStore(rootURL: temporaryRoot())
        let viewModel = MeetingViewModel(
            store: store,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            summaryService: SummaryService(provider: provider, fileStore: fileStore),
            fileStore: fileStore
        )
        viewModel.selectMeeting(meeting)

        viewModel.selectSummaryTemplate(.oneOnOne)
        await waitUntilAsync {
            await provider.didStart(templateID: SummaryTemplate.oneOnOne.id)
        }

        viewModel.selectSummaryTemplate(.projectSync)
        await waitUntilAsync {
            await provider.didStart(templateID: SummaryTemplate.projectSync.id)
        }

        XCTAssertEqual(viewModel.currentMeeting.summary, "Resumo original.")
        await provider.releaseProjectSync()
        await waitUntil {
            viewModel.currentMeeting.summary.contains(SummaryTemplate.projectSync.id)
        }

        XCTAssertEqual(viewModel.currentMeeting.templateId, SummaryTemplate.projectSync.id)
        XCTAssertFalse(viewModel.currentMeeting.summary.contains(SummaryTemplate.oneOnOne.id))
        XCTAssertEqual(
            try store.loadMeetings().first?.templateId,
            SummaryTemplate.projectSync.id
        )
    }

    func testRecordingMetadataContainsDayTimeAndTotalDuration() {
        let startedAt = Date(timeIntervalSince1970: 1_756_000_000)
        let meeting = Meeting(
            createdAt: startedAt,
            recordedDuration: 3_725,
            title: "Reunião com metadados"
        )

        XCTAssertEqual(
            meeting.recordingMetadataText,
            "\(meeting.recordingDateText) · \(meeting.recordingTimeText) · 1 h 02 min 05 s"
        )
        XCTAssertEqual(
            meeting.recordingTimeText,
            startedAt.formatted(date: .omitted, time: .shortened)
        )
    }

    func testDeletedCustomTemplateIsRestoredFromMeetingSnapshotAndUsedForRegeneration() async throws {
        let deletedTemplate = SummaryTemplate(
            id: "custom-quarterly-review",
            displayName: "Revisão trimestral histórica",
            instructions: "Preserve métricas, decisões e ressalvas exatamente como foram ditas.",
            sections: ["Resultados confirmados", "Riscos observados", "Compromissos explícitos"],
            isBuiltIn: false
        )
        let meeting = Meeting(
            title: "Revisão do trimestre",
            state: .completed,
            templateId: deletedTemplate.id,
            customTemplateStructure: deletedTemplate.snapshotValue,
            transcript: "A receita cresceu 12%. Marina entregará o relatório na sexta-feira.",
            summary: "## Resultados confirmados\n\nA receita cresceu 12%."
        )
        let store = MockMeetingStore(meetings: [meeting])
        let provider = TemplateSelectionSummaryProvider()
        let fileStore = LocalMeetingFileStore(rootURL: temporaryRoot())
        let viewModel = MeetingViewModel(
            store: store,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            summaryService: SummaryService(provider: provider, fileStore: fileStore),
            fileStore: fileStore
        )

        XCTAssertFalse(viewModel.templates.contains(where: { $0.id == deletedTemplate.id }))

        viewModel.selectMeeting(meeting)

        XCTAssertEqual(viewModel.selectedTemplate.id, deletedTemplate.id)
        XCTAssertEqual(viewModel.selectedTemplate.displayName, deletedTemplate.displayName)
        XCTAssertEqual(viewModel.selectedTemplate.instructions, deletedTemplate.instructions)
        XCTAssertEqual(viewModel.selectedTemplate.sections, deletedTemplate.sections)
        XCTAssertFalse(viewModel.selectedTemplate.isBuiltIn)

        viewModel.retrySummary()
        await waitUntil {
            viewModel.meetings.first?.summary.contains("Resumo regenerado.") == true
        }

        let generatedTemplate = await provider.lastTemplate()
        XCTAssertEqual(generatedTemplate?.id, deletedTemplate.id)
        XCTAssertEqual(generatedTemplate?.displayName, deletedTemplate.displayName)
        XCTAssertEqual(generatedTemplate?.instructions, deletedTemplate.instructions)
        XCTAssertEqual(generatedTemplate?.sections, deletedTemplate.sections)
        XCTAssertEqual(generatedTemplate?.isBuiltIn, false)

        let persistedMeeting = try XCTUnwrap(
            try store.loadMeetings().first(where: { $0.id == meeting.id })
        )
        let persistedTemplate = SummaryTemplate.restoringSnapshot(
            persistedMeeting.customTemplateStructure,
            templateID: persistedMeeting.templateId
        )
        XCTAssertEqual(persistedTemplate.displayName, deletedTemplate.displayName)
        XCTAssertEqual(persistedTemplate.instructions, deletedTemplate.instructions)
        XCTAssertEqual(persistedTemplate.sections, deletedTemplate.sections)
    }

    func testLegacyVersionTwoSnapshotStillRestoresInstructionsAndSections() throws {
        let json = """
        {"instructions":"Orientação histórica.","sections":["Decisões","Pendências"]}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let legacySnapshot = "qapia-template-v2:" + data.base64EncodedString()
        let currentLibraryTemplate = SummaryTemplate(
            id: "legacy-custom",
            displayName: "Nome disponível na biblioteca",
            instructions: "Orientação atual.",
            sections: ["Estrutura atual"],
            isBuiltIn: false
        )

        let restored = SummaryTemplate.restoringSnapshot(
            legacySnapshot,
            templateID: currentLibraryTemplate.id,
            fallback: currentLibraryTemplate
        )

        XCTAssertEqual(restored.id, currentLibraryTemplate.id)
        XCTAssertEqual(restored.displayName, currentLibraryTemplate.displayName)
        XCTAssertEqual(restored.instructions, "Orientação histórica.")
        XCTAssertEqual(restored.sections, ["Decisões", "Pendências"])
    }

    private func makeRecordingFixture(
        meetings: [Meeting] = []
    ) -> (viewModel: MeetingViewModel, store: MockMeetingStore) {
        let store = MockMeetingStore(meetings: meetings)
        let fileStore = LocalMeetingFileStore(rootURL: temporaryRoot())
        let viewModel = MeetingViewModel(
            store: store,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: TemplateSelectionCaptureService(),
                fileStore: fileStore
            ),
            fileStore: fileStore
        )
        return (viewModel, store)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "A condição esperada não ocorreu dentro do prazo.")
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let didMeetCondition = await condition()
        XCTAssertTrue(didMeetCondition, "A condição esperada não ocorreu dentro do prazo.")
    }
}

@MainActor
private final class TemplateSelectionCaptureService: AudioCaptureService {
    private var activeURL: URL?

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        activeURL = fileURL
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let activeURL else { throw RecordingError.noActiveRecording }
        self.activeURL = nil
        return CapturedAudio(fileURL: activeURL, duration: 1)
    }
}

private actor TemplateSelectionSummaryProvider: SummaryProvider {
    private var templates: [SummaryTemplate] = []

    func generateSummary(
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String {
        templates.append(template)
        return "## \(template.sections[0])\n\nResumo regenerado."
    }

    func lastTemplateID() -> String? {
        templates.last?.id
    }

    func lastTemplate() -> SummaryTemplate? {
        templates.last
    }

    func callCount() -> Int {
        templates.count
    }
}

private actor RacingTemplateSummaryProvider: SummaryProvider {
    private var startedTemplateIDs: [String] = []
    private var projectSyncContinuation: CheckedContinuation<Void, Never>?

    func generateSummary(
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String {
        startedTemplateIDs.append(template.id)

        if template.id == SummaryTemplate.oneOnOne.id {
            // Simulates a provider that returns a value even after cancellation.
            try? await Task.sleep(for: .seconds(5))
        } else if template.id == SummaryTemplate.projectSync.id {
            await withCheckedContinuation { continuation in
                projectSyncContinuation = continuation
            }
        }

        return "## Resultado\n\nResumo para \(template.id)."
    }

    func didStart(templateID: String) -> Bool {
        startedTemplateIDs.contains(templateID)
    }

    func releaseProjectSync() {
        projectSyncContinuation?.resume()
        projectSyncContinuation = nil
    }
}

@MainActor
private final class FailingTemplateChangeMeetingStore: MeetingStore {
    private let meeting: Meeting

    init(meeting: Meeting) {
        self.meeting = meeting
    }

    func loadMeetings() throws -> [Meeting] {
        [meeting]
    }

    func save(_ meeting: Meeting) throws {
        throw MeetingStoreError.unavailable("Falha de persistência simulada.")
    }

    func delete(id: UUID) throws {}
}
