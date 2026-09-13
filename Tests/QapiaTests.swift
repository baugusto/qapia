@preconcurrency import AVFoundation
import CoreAudio
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

    func testMeetingEndDetectionRequiresContinuousLossOfMeetingSignal() {
        let start = Date(timeIntervalSince1970: 1_000)
        var state = MeetingEndDetectionState()

        XCTAssertFalse(state.observe(hasMeetingWindow: false, audioLevel: 0, at: start, gracePeriod: 30))
        XCTAssertFalse(state.observe(hasMeetingWindow: true, audioLevel: 0.2, at: start, gracePeriod: 30))
        XCTAssertTrue(state.hasDetectedMeetingWindow)
        XCTAssertFalse(state.observe(hasMeetingWindow: false, audioLevel: 0.4, at: start.addingTimeInterval(5), gracePeriod: 30))
        XCTAssertTrue(state.observe(hasMeetingWindow: false, audioLevel: 0.4, at: start.addingTimeInterval(35), gracePeriod: 30))
    }

    func testActiveMeetingAudioProcessPreventsSilenceFallbackAndScheduledStop() {
        let start = Date(timeIntervalSince1970: 1_500)
        var state = MeetingEndDetectionState()

        XCTAssertFalse(state.observe(hasMeetingWindow: true, audioLevel: 0.2, at: start))
        XCTAssertFalse(state.observe(
            hasMeetingWindow: true,
            audioLevel: 0,
            at: start.addingTimeInterval(600),
            scheduledEnd: start.addingTimeInterval(60),
            scheduledEndGracePeriod: 45,
            silenceFallbackPeriod: 180
        ))
    }

    func testSupportedMeetingAudioProcessesMatchWithoutInspectingWindows() {
        XCTAssertTrue(SupportedMeetingAudioProcessDetector.matches(
            bundleIdentifier: "us.zoom.xos",
            applicationName: "zoom.us"
        ))
        XCTAssertTrue(SupportedMeetingAudioProcessDetector.matches(
            bundleIdentifier: "com.microsoft.teams2",
            applicationName: "Microsoft Teams"
        ))
        XCTAssertTrue(SupportedMeetingAudioProcessDetector.matches(
            bundleIdentifier: "com.google.Chrome.helper",
            applicationName: "Google Chrome Helper"
        ))
        XCTAssertFalse(SupportedMeetingAudioProcessDetector.matches(
            bundleIdentifier: "com.apple.Music",
            applicationName: "Music"
        ))
    }

    func testBrowserOutputWithoutMicrophoneInputIsNotMeetingActivity() {
        let youtubeActivity = SupportedMeetingAudioProcessDetector.isActiveMeetingActivity(
            bundleIdentifier: "com.google.Chrome.helper",
            applicationName: "Google Chrome Helper",
            isRunning: true,
            isRunningInput: false
        )
        XCTAssertFalse(youtubeActivity)

        var state = MeetingEndDetectionState()
        let start = Date(timeIntervalSince1970: 1_700)
        XCTAssertFalse(state.observe(
            hasMeetingWindow: youtubeActivity,
            audioLevel: 0.3,
            at: start,
            gracePeriod: 30,
            silenceFallbackPeriod: 180
        ))
        XCTAssertFalse(state.observe(
            hasMeetingWindow: false,
            audioLevel: 0,
            at: start.addingTimeInterval(35),
            gracePeriod: 30,
            silenceFallbackPeriod: 180
        ))
    }

    func testBrowserMeetingEndIsNotMaskedByAudioFromAnotherTab() {
        let browserMeeting = SupportedMeetingAudioProcessDetector.isActiveMeetingActivity(
            bundleIdentifier: "com.google.Chrome.helper",
            applicationName: "Google Chrome Helper",
            isRunning: true,
            isRunningInput: true
        )
        let unrelatedTabAudio = SupportedMeetingAudioProcessDetector.isActiveMeetingActivity(
            bundleIdentifier: "com.google.Chrome.helper",
            applicationName: "Google Chrome Helper",
            isRunning: true,
            isRunningInput: false
        )
        XCTAssertTrue(browserMeeting)
        XCTAssertFalse(unrelatedTabAudio)

        var state = MeetingEndDetectionState()
        let start = Date(timeIntervalSince1970: 1_800)
        XCTAssertFalse(state.observe(
            hasMeetingWindow: browserMeeting,
            audioLevel: 0.2,
            at: start,
            gracePeriod: 30
        ))
        XCTAssertFalse(state.observe(
            hasMeetingWindow: unrelatedTabAudio,
            audioLevel: 0.4,
            at: start.addingTimeInterval(1),
            gracePeriod: 30
        ))
        XCTAssertTrue(state.observe(
            hasMeetingWindow: unrelatedTabAudio,
            audioLevel: 0.4,
            at: start.addingTimeInterval(31),
            gracePeriod: 30
        ))
    }

    func testNativeZoomAndTeamsRemainMeetingActivityWithoutInputFlag() {
        XCTAssertTrue(SupportedMeetingAudioProcessDetector.isActiveMeetingActivity(
            bundleIdentifier: "us.zoom.xos",
            applicationName: "zoom.us",
            isRunning: true,
            isRunningInput: false
        ))
        XCTAssertTrue(SupportedMeetingAudioProcessDetector.isActiveMeetingActivity(
            bundleIdentifier: "com.microsoft.teams2",
            applicationName: "Microsoft Teams",
            isRunning: true,
            isRunningInput: false
        ))
    }

    func testMeetingEndDetectionUsesScheduledEndWithoutScreenAccess() {
        let start = Date(timeIntervalSince1970: 2_000)
        let scheduledEnd = start.addingTimeInterval(60)
        var state = MeetingEndDetectionState()

        XCTAssertFalse(state.observe(hasMeetingWindow: false, audioLevel: 0.2, at: start))
        XCTAssertFalse(state.observe(
            hasMeetingWindow: false,
            audioLevel: 0,
            at: scheduledEnd,
            scheduledEnd: scheduledEnd,
            scheduledEndGracePeriod: 45
        ))
        XCTAssertTrue(state.observe(
            hasMeetingWindow: false,
            audioLevel: 0,
            at: scheduledEnd.addingTimeInterval(45),
            scheduledEnd: scheduledEnd,
            scheduledEndGracePeriod: 45
        ))
    }

    func testInfoPlistRequestsAudioButNotScreenCapturePermission() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: projectRoot.appendingPathComponent("App/Info.plist")))

        XCTAssertNotNil(plist["NSAudioCaptureUsageDescription"])
        XCTAssertNotNil(plist["NSMicrophoneUsageDescription"])
        XCTAssertNil(plist["NSScreenCaptureUsageDescription"])
    }

    func testVersion12BundlesTheGoogleCalendarOAuthConfiguration() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: projectRoot.appendingPathComponent("App/Info.plist")))
        let clientID = try XCTUnwrap(plist["QAPiaGoogleClientID"] as? String)
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = try XCTUnwrap(urlTypes.first?["CFBundleURLSchemes"] as? [String])

        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "1.2.1")
        XCTAssertEqual(clientID, "666747177192-ndh5joi0an6ohq7m9q2qbnngjbkhtcds.apps.googleusercontent.com")
        XCTAssertEqual(
            schemes.first,
            "com.googleusercontent.apps.666747177192-ndh5joi0an6ohq7m9q2qbnngjbkhtcds"
        )
    }

    func testGoogleOAuthConfigurationDerivesAndValidatesItsCallbackScheme() {
        let valid = GoogleOAuthConfiguration(
            clientID: " 666747177192-ndh5joi0an6ohq7m9q2qbnngjbkhtcds.apps.googleusercontent.com "
        )
        let invalid = GoogleOAuthConfiguration(clientID: "client-id-incompleto")

        XCTAssertEqual(
            valid.callbackScheme,
            "com.googleusercontent.apps.666747177192-ndh5joi0an6ohq7m9q2qbnngjbkhtcds"
        )
        XCTAssertNil(invalid.callbackScheme)
    }

    func testStandaloneEntitlementsSupportBundledWhisperWithoutScreenOrSandboxAccess() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = projectRoot
            .appendingPathComponent("Scripts/QAPia-standalone.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(entitlements["com.apple.security.device.audio-input"] as? Bool, true)
        XCTAssertNil(entitlements["com.apple.security.cs.disable-library-validation"])
        XCTAssertNil(entitlements["com.apple.security.app-sandbox"])
        XCTAssertNil(entitlements["com.apple.security.device.camera"])
        XCTAssertNil(entitlements["com.apple.security.personal-information.screen-recording"])
    }

    func testStandalonePackagerRefusesToMislabelANonDeveloperIDBuildAsPortable() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("Scripts/package-standalone.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("QAPIA_ALLOW_LOCAL_PACKAGE"))
        XCTAssertTrue(script.contains("não é válida para distribuição direta pelo Gatekeeper"))
        XCTAssertTrue(script.contains("-$version-local.dmg"))
        XCTAssertTrue(script.contains("Um pacote portátil exige notarização"))
        XCTAssertTrue(script.contains("notary_status"))
        XCTAssertTrue(script.contains("Accepted"))
    }

    func testAutomaticStandaloneSigningPreservesTheExistingTCCIdentity() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("Scripts/build-app-bundle.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("explicit_signing_identity=\"${QAPIA_SIGNING_IDENTITY:-}\""))
        XCTAssertTrue(
            script.contains(
                "if [ -z \"$explicit_signing_identity\" ] && [ -n \"$previous_designated_requirement\" ]; then"
            )
        )
        XCTAssertTrue(script.contains("preserve_existing_requirement=true"))
        XCTAssertTrue(script.contains("A nova assinatura mudaria a identidade TCC do app"))
    }

    func testApplicationDoesNotReadScreenOrWindowContents() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDirectory = projectRoot.appendingPathComponent("App", isDirectory: true)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: nil
        ) + FileManager.default.contentsOfDirectory(
            at: appDirectory.appendingPathComponent("Views", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let source = try sourceURLs
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(source.contains("CGWindowListCopyWindowInfo"))
        XCTAssertFalse(source.contains("ScreenCaptureKit"))
        XCTAssertFalse(source.contains("SCShareableContent"))
    }

    func testMeetingDocumentViewportAvoidsUnboundedLazySelectableLayout() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stateViews = try String(
            contentsOf: projectRoot.appendingPathComponent("App/Views/StateViews.swift"),
            encoding: .utf8
        )
        let markdownView = try String(
            contentsOf: projectRoot.appendingPathComponent("App/Views/MarkdownSummaryView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            stateViews.contains(".frame(minHeight: 190, idealHeight: 440, maxHeight: 540)"),
            "The nested meeting document scroll view must keep a finite viewport."
        )
        XCTAssertFalse(
            markdownView.contains("LazyVStack(alignment:"),
            "A lazy stack can repeatedly invalidate selectable Markdown layout on macOS."
        )
        XCTAssertFalse(
            markdownView.contains(".textSelection(.enabled)"),
            "Read-mode selection overlays can re-enter layout; copy and edit remain available."
        )
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

    func testSummaryPresentationRemovesOnlyRedundantLeadingSpeechMarkers() {
        let markdown = """
        ## Objetivo da reunião

        -Vamos marcar a reunião.

        ## Principais pontos abordados

        - -Medeiros não participará.
        + —Não houve alteração do áudio.
          * -Bruno enviará a ata.
        - -5% de variação foi registrado.
        - --verbose permanece uma opção.
        - -n permanece uma opção curta.
        - Pós-venda e follow-up em 10-15 dias.

        1. -Então será feita a validação.

        ```text
        - -Marcador preservado no código.
        ```
        """

        XCTAssertEqual(
            MarkdownPlainTextFormatter.presentationMarkdown(from: markdown),
            """
            ## Objetivo da reunião

            Vamos marcar a reunião.

            ## Principais pontos abordados

            - Medeiros não participará.
            + Não houve alteração do áudio.
              * Bruno enviará a ata.
            - -5% de variação foi registrado.
            - --verbose permanece uma opção.
            - -n permanece uma opção curta.
            - Pós-venda e follow-up em 10-15 dias.

            1. Então será feita a validação.

            ```text
            - -Marcador preservado no código.
            ```
            """
        )
    }

    func testCopySummaryRemovesRedundantSpeechMarkerFromBulletText() {
        let markdown = """
        ## Principais pontos abordados

        - -Medeiros não participará.
        - Pós-venda e follow-up em 10-15 dias.
        - -5% de variação foi registrado.
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
            Principais pontos abordados

            • Medeiros não participará.
            • Pós-venda e follow-up em 10-15 dias.
            • -5% de variação foi registrado.
            """
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
            viewModel.meetings.first?.state == .completed
        }
        XCTAssertEqual(viewModel.screen, .empty)
        XCTAssertNil(viewModel.selectedMeetingID)
        XCTAssertEqual(viewModel.meetings.first?.state, .completed)
        XCTAssertEqual(viewModel.meetings.first?.recordingSegments.count, 1)
        XCTAssertEqual(viewModel.meetings.first?.transcript, "Transcrição concluída.")
        XCTAssertEqual(viewModel.meetings.first?.summary, "# Resumo\n\nTudo concluído.")

        let persisted = try XCTUnwrap(meetingStore.loadMeetings().first)
        XCTAssertEqual(persisted.state, .completed)
        XCTAssertEqual(persisted.recordingSegments.count, 1)
        XCTAssertEqual(persisted.transcript, "Transcrição concluída.")
        XCTAssertEqual(persisted.summary, "# Resumo\n\nTudo concluído.")
    }

    func testConsecutiveRecordingDefersTranscriptionAndLosesNoMeeting() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let captureService = FakeAudioCaptureService(durations: [4, 5])
        let viewModel = MeetingViewModel(
            store: try SwiftDataMeetingStore(inMemory: true),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(captureService: captureService, fileStore: fileStore),
            transcriptionService: TranscriptionService(
                whisperService: DelayedFakeWhisperService(transcript: "Transcrição preservada."),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo\n\nProcessado em segundo plano."),
                fileStore: fileStore
            )
        )

        await viewModel.beginRecording()
        let firstID = try XCTUnwrap(viewModel.selectedMeetingID)
        await viewModel.finishActiveRecording()
        XCTAssertEqual(viewModel.screen, .empty)

        await viewModel.beginRecording()
        let secondID = try XCTUnwrap(viewModel.selectedMeetingID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertEqual(viewModel.meetings.first(where: { $0.id == firstID })?.state, .preparingAudio)

        await viewModel.finishActiveRecording()
        await waitUntil(timeout: 8) {
            viewModel.meetings.filter { $0.state == .completed }.count == 2
        }

        XCTAssertEqual(Set(viewModel.meetings.map(\.id)), Set([firstID, secondID]))
        XCTAssertTrue(viewModel.meetings.allSatisfy { !$0.transcript.isEmpty && !$0.summary.isEmpty })
    }

    func testSecondRecordingStartsWhileFirstAudioIsStillFinalizing() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let captureService = SuspendedFinalizationAudioCaptureService()
        let viewModel = MeetingViewModel(
            store: try SwiftDataMeetingStore(inMemory: true),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(captureService: captureService, fileStore: fileStore),
            transcriptionService: TranscriptionService(
                whisperService: FakeWhisperService(transcripts: [1: "Áudio preservado."]),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo\n\nConcluído."),
                fileStore: fileStore
            )
        )

        await viewModel.beginRecording()
        let firstID = try XCTUnwrap(viewModel.selectedMeetingID)
        let firstFinish = Task { await viewModel.finishActiveRecording() }
        await waitUntil {
            captureService.firstStopIsWaiting && viewModel.screen == .empty
        }

        let finalizingMeeting = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == firstID })
        )
        viewModel.selectMeeting(finalizingMeeting)
        try await Task.sleep(for: .milliseconds(100))
        let stillFinalizing = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == firstID })
        )
        XCTAssertEqual(stillFinalizing.state, .preparingAudio)
        XCTAssertTrue(stillFinalizing.recordingSegments.isEmpty)
        XCTAssertFalse(viewModel.canDeleteMeeting(stillFinalizing))
        viewModel.showRecordings()

        await viewModel.beginRecording()
        let secondID = try XCTUnwrap(viewModel.selectedMeetingID)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertEqual(captureService.startedURLs.count, 2)

        captureService.completeFirstStop()
        await firstFinish.value

        XCTAssertEqual(viewModel.selectedMeetingID, secondID)
        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == firstID })?.recordingSegments.count,
            1
        )

        await viewModel.finishActiveRecording()
    }

    func testAudioLevelAnalyzerNormalizesAndSmoothsSafely() {
        XCTAssertEqual(AudioLevelAnalyzer.rootMeanSquare(of: [1, -1, 1, -1]), 1, accuracy: 0.001)
        XCTAssertEqual(AudioLevelAnalyzer.normalizedLevel(fromRMS: 0), 0)
        XCTAssertEqual(AudioLevelAnalyzer.normalizedLevel(fromRMS: 0.001), 0)
        XCTAssertGreaterThan(AudioLevelAnalyzer.normalizedLevel(fromRMS: 0.1), 0.5)
        XCTAssertEqual(AudioLevelAnalyzer.normalizedLevel(fromRMS: .nan), 0)
        XCTAssertEqual(AudioLevelAnalyzer.normalizedLevel(fromDecibels: -160), 0)
        XCTAssertGreaterThan(AudioLevelAnalyzer.normalizedLevel(fromDecibels: -10), 0.7)

        let attack = AudioLevelAnalyzer.smoothed(previous: 0, incoming: 1)
        let release = AudioLevelAnalyzer.smoothed(previous: 1, incoming: 0)
        XCTAssertGreaterThan(attack, 1 - release)

        let sample = AudioLevelSample(microphone: 2, system: -.infinity)
        XCTAssertEqual(sample.microphone, 1)
        XCTAssertEqual(sample.system, 0)
        XCTAssertEqual(sample.combined, 1)
    }

    func testWaveformAdvancesToSilenceEvenWhenLevelDoesNotChange() {
        var samples = Array(repeating: Float(0.9), count: 40)
        for _ in 0..<40 {
            samples = AudioLevelAnalyzer.advancingWaveform(samples, incoming: 0, count: 40)
        }
        XCTAssertEqual(samples, Array(repeating: Float(0.05), count: 40))
    }

    func testRealtimeWaveformIsFlatAtSilenceAndMovesWithAudio() {
        let silentFrameA = (0..<40).map {
            AudioLevelAnalyzer.animatedBarLevel(audioLevel: 0, phase: 10, index: $0, count: 40)
        }
        let silentFrameB = (0..<40).map {
            AudioLevelAnalyzer.animatedBarLevel(audioLevel: 0, phase: 11, index: $0, count: 40)
        }
        XCTAssertEqual(silentFrameA, Array(repeating: 0.05, count: 40))
        XCTAssertEqual(silentFrameA, silentFrameB)

        let audibleFrameA = (0..<40).map {
            AudioLevelAnalyzer.animatedBarLevel(audioLevel: 0.7, phase: 10, index: $0, count: 40)
        }
        let audibleFrameB = (0..<40).map {
            AudioLevelAnalyzer.animatedBarLevel(audioLevel: 0.7, phase: 10.1, index: $0, count: 40)
        }
        XCTAssertNotEqual(audibleFrameA, audibleFrameB)
        XCTAssertGreaterThan(audibleFrameA.max() ?? 0, 0.3)
    }

    func testSystemAudioGraphDoesNotWaitForTheFirstAudibleSound() {
        let description = CoreAudioTapCaptureService.aggregateDeviceDescription(
            uid: "test-audio-graph",
            tapUID: "test-tap"
        )

        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertNil(description[kAudioAggregateDeviceTapAutoStartKey])
        let tapList = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        XCTAssertEqual(tapList?.count, 1)
        XCTAssertEqual(tapList?.first?[kAudioSubTapUIDKey] as? String, "test-tap")
    }

    func testOnlyARealCoreAudioPermissionErrorOpensSystemSettings() {
        let denied = AudioTapOperationError(
            status: kAudioDevicePermissionsError,
            message: "Acesso negado"
        )
        XCTAssertEqual(
            CoreAudioTapCaptureService.recordingError(for: denied),
            .systemAudioPermissionDenied
        )

        let staleObject = AudioTapOperationError(
            status: kAudioHardwareBadObjectError,
            message: "Dispositivo ainda não pronto"
        )
        guard case let .captureFailed(message) = CoreAudioTapCaptureService.recordingError(for: staleObject) else {
            return XCTFail("Uma falha de ciclo de vida não pode ser apresentada como falta de permissão.")
        }
        XCTAssertTrue(message.contains("!obj"))
    }

    func testRecordingRemainsIdleAndRejectsDuplicateStartsWhileHardwareIsPreparing() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureService = SuspendedStartAudioCaptureService()
        let session = RecordingSession(
            captureService: captureService,
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )
        let viewModel = MeetingViewModel(
            clipboard: MemoryClipboardService(),
            recordingSession: session,
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler()
        )

        viewModel.startRecording()
        await waitUntil {
            viewModel.isStartingRecording && captureService.startAttempts == 1
        }
        XCTAssertEqual(viewModel.screen, .empty)
        XCTAssertEqual(viewModel.meetings.first?.state, .idle)

        viewModel.startRecording()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(captureService.startAttempts, 1)

        captureService.completeStart()
        await waitUntil { viewModel.screen == .recording }
        XCTAssertFalse(viewModel.isStartingRecording)
        XCTAssertEqual(viewModel.meetings.first?.state, .recording)

        await viewModel.pauseActiveRecording()
    }

    func testRecordingDoesNotStartWhenDurableMeetingCannotBeSaved() async {
        let captureService = FakeAudioCaptureService(durations: [1])
        let viewModel = MeetingViewModel(
            store: UnavailableMeetingStore(
                error: MeetingStoreError.unavailable("disco indisponível")
            ),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(captureService: captureService),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler()
        )

        await viewModel.beginRecording()

        XCTAssertTrue(captureService.startedURLs.isEmpty)
        XCTAssertTrue(viewModel.meetings.isEmpty)
        XCTAssertNil(viewModel.selectedMeetingID)
        XCTAssertEqual(viewModel.screen, .empty)
        XCTAssertEqual(viewModel.errorTitle, "Não foi possível salvar a reunião")
        XCTAssertNotNil(viewModel.recordingError)
    }

    func testTranscriptionDoesNotRestartWhileNewRecordingIsPreparing() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let pendingID = UUID()
        let pendingMeeting = Meeting(
            id: pendingID,
            title: "Processamento anterior",
            state: .preparingAudio,
            recordingSegments: [
                RecordingSegment(
                    meetingID: pendingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.caf"),
                    recordedDuration: 2
                )
            ]
        )
        let invocationCounter = WhisperInvocationCounter()
        let captureService = SuspendedStartAudioCaptureService()
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [pendingMeeting]),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(captureService: captureService, fileStore: fileStore),
            transcriptionService: TranscriptionService(
                whisperService: SuspendFirstWhisperService(counter: invocationCounter),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo"),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: FakeLocalResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil { invocationCounter.count == 1 }

        viewModel.startRecording()
        await waitUntil {
            viewModel.isStartingRecording && captureService.startAttempts == 1
        }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(invocationCounter.count, 1)
        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == pendingID })?.state,
            .preparingAudio
        )

        captureService.completeStart()
        await waitUntil { viewModel.screen == .recording }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(invocationCounter.count, 1)

        await viewModel.pauseActiveRecording()
    }

    func testNewRecordingCancelsExpensiveTranscriptionBeforeOpeningCaptureAndResumesAfterFinish() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let pendingID = UUID()
        let pendingMeeting = Meeting(
            id: pendingID,
            createdAt: Date(timeIntervalSince1970: 1),
            title: "Transcrição de alta precisão",
            state: .transcribing,
            transcript: "Transcrição anterior preservada.",
            summary: "# Resumo anterior",
            recordingSegments: [
                RecordingSegment(
                    meetingID: pendingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 35
                )
            ]
        )
        let priorityProbe = BackgroundWorkPriorityProbe()
        let captureService = PriorityObservingAudioCaptureService(probe: priorityProbe)
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [pendingMeeting]),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(captureService: captureService, fileStore: fileStore),
            transcriptionService: TranscriptionService(
                whisperService: CancellableThenSuccessfulWhisperService(
                    probe: priorityProbe,
                    cancellableMeetingID: pendingID
                ),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo\n\nProcessado após a gravação."),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: FakeLocalResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil { priorityProbe.transcriptionInvocationCount(for: pendingID) == 1 }
        XCTAssertFalse(priorityProbe.cancellationObserved)

        await viewModel.beginRecording()

        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertTrue(priorityProbe.cancellationObserved)
        XCTAssertTrue(priorityProbe.captureStartedAfterBackgroundCancellation)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(priorityProbe.transcriptionInvocationCount(for: pendingID), 1)
        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == pendingID })?.transcript,
            "Transcrição anterior preservada."
        )

        await viewModel.finishActiveRecording()
        await waitUntil(timeout: 6) {
            viewModel.meetings.first(where: { $0.id == pendingID })?.state == .completed
        }

        XCTAssertEqual(priorityProbe.transcriptionInvocationCount(for: pendingID), 2)
        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == pendingID })?.transcript,
            "Transcrição fiel retomada."
        )
        await waitUntil(timeout: 6) {
            viewModel.meetings.allSatisfy { $0.state == .completed }
        }
    }

    func testNewRecordingWaitsForCancelledWhisperWorkerToActuallyExit() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let pendingID = UUID()
        let pendingMeeting = Meeting(
            id: pendingID,
            createdAt: Date(timeIntervalSince1970: 1),
            title: "Worker ainda encerrando",
            state: .transcribing,
            recordingSegments: [
                RecordingSegment(
                    meetingID: pendingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 35
                )
            ]
        )
        let priorityProbe = BackgroundWorkPriorityProbe()
        let workerController = UninterruptibleWhisperController()
        let captureService = PriorityObservingAudioCaptureService(probe: priorityProbe)
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [pendingMeeting]),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(captureService: captureService, fileStore: fileStore),
            transcriptionService: TranscriptionService(
                whisperService: UninterruptibleThenSuccessfulWhisperService(
                    probe: priorityProbe,
                    controller: workerController,
                    blockedMeetingID: pendingID
                ),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo"),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: FakeLocalResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil {
            priorityProbe.transcriptionInvocationCount(for: pendingID) == 1
                && workerController.isWaiting
        }

        let startTask = Task { await viewModel.beginRecording() }
        await waitUntil { priorityProbe.cancellationObserved }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(priorityProbe.cancelledWorkerExited)
        XCTAssertEqual(priorityProbe.captureStartCount, 0)
        XCTAssertNotEqual(viewModel.screen, .recording)

        workerController.release()
        await startTask.value

        XCTAssertTrue(priorityProbe.cancelledWorkerExited)
        XCTAssertTrue(priorityProbe.captureStartedAfterWorkerExit)
        XCTAssertEqual(priorityProbe.captureStartCount, 1)
        XCTAssertEqual(viewModel.screen, .recording)

        await viewModel.finishActiveRecording()
        await waitUntil(timeout: 6) {
            viewModel.meetings.allSatisfy { $0.state == .completed }
        }
    }

    func testRetryTranscriptionKeepsPreviousTranscriptUntilReplacementSucceeds() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let oldTranscript = "Versão anterior que continua disponível."
        let replacementTranscript = "Versão nova, mais fiel ao áudio."
        try fileStore.writeTranscript(oldTranscript, meetingID: meetingID)
        let meeting = Meeting(
            id: meetingID,
            title: "Reprocessar localmente",
            state: .completed,
            transcript: oldTranscript,
            summary: "# Resumo anterior",
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 35
                )
            ]
        )
        let controller = SuspendedReplacementTranscriptionController()
        defer { controller.completeIfNeeded(with: replacementTranscript) }
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            clipboard: MemoryClipboardService(),
            transcriptionService: TranscriptionService(
                whisperService: SuspendedReplacementWhisperService(controller: controller),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo novo"),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore
        )

        viewModel.selectMeeting(meeting)
        viewModel.retryTranscription()
        await waitUntil { controller.isWaiting }

        XCTAssertEqual(viewModel.screen, .processing)
        XCTAssertEqual(viewModel.detailTab, .transcript)
        XCTAssertEqual(viewModel.selectedMeeting?.transcript, oldTranscript)
        XCTAssertEqual(
            try String(contentsOf: fileStore.transcriptURL(meetingID: meetingID), encoding: .utf8),
            oldTranscript
        )

        controller.completeIfNeeded(with: replacementTranscript)
        await waitUntil { viewModel.selectedMeeting?.state == .completed }

        XCTAssertEqual(viewModel.selectedMeeting?.transcript, replacementTranscript)
        XCTAssertEqual(viewModel.selectedMeeting?.summary, "# Resumo novo")
        XCTAssertEqual(
            try String(contentsOf: fileStore.transcriptURL(meetingID: meetingID), encoding: .utf8),
            replacementTranscript
        )
    }

    func testFailedRetryTranscriptionPreservesPreviousTranscriptAndFile() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let oldTranscript = "Transcrição anterior confiável."
        try fileStore.writeTranscript(oldTranscript, meetingID: meetingID)
        let meeting = Meeting(
            id: meetingID,
            title: "Falha segura de reprocessamento",
            state: .completed,
            transcript: oldTranscript,
            summary: "# Resumo anterior",
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 35
                )
            ]
        )
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            clipboard: MemoryClipboardService(),
            transcriptionService: TranscriptionService(
                whisperService: FakeWhisperService(
                    transcripts: [:],
                    error: .transcriptionFailed("falha simulada")
                ),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore
        )

        viewModel.selectMeeting(meeting)
        viewModel.retryTranscription()
        await waitUntil { viewModel.selectedMeeting?.state == .failed }

        XCTAssertEqual(viewModel.selectedMeeting?.transcript, oldTranscript)
        XCTAssertEqual(viewModel.selectedMeeting?.summary, "# Resumo anterior")
        XCTAssertEqual(
            try String(contentsOf: fileStore.transcriptURL(meetingID: meetingID), encoding: .utf8),
            oldTranscript
        )
    }

    func testFailedSummaryAfterRetranscriptionNeverLeavesOldSummaryOnNewTranscript() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let oldTranscript = "Transcrição anterior."
        let oldSummary = "# Resumo anterior"
        let newTranscript = "Transcrição nova e fiel ao áudio."
        try fileStore.writeTranscript(oldTranscript, meetingID: meetingID)
        try fileStore.writeSummary(oldSummary, meetingID: meetingID)
        let meeting = Meeting(
            id: meetingID,
            title: "Falha segura do resumo",
            state: .completed,
            transcript: oldTranscript,
            summary: oldSummary,
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 35
                )
            ]
        )
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            clipboard: MemoryClipboardService(),
            transcriptionService: TranscriptionService(
                whisperService: FakeWhisperService(transcripts: [1: newTranscript]),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(error: .generationFailed("falha simulada")),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore
        )

        viewModel.selectMeeting(meeting)
        viewModel.retryTranscription()
        await waitUntil { viewModel.selectedMeeting?.state == .failed }

        XCTAssertEqual(viewModel.selectedMeeting?.transcript, newTranscript)
        XCTAssertEqual(viewModel.selectedMeeting?.summary, "")
        XCTAssertEqual(
            try String(contentsOf: fileStore.transcriptURL(meetingID: meetingID), encoding: .utf8),
            newTranscript
        )
        XCTAssertEqual(
            try String(contentsOf: fileStore.summaryURL(meetingID: meetingID), encoding: .utf8),
            ""
        )
    }

    func testRejectedTranscriptCommitRestoresPreviousTranscriptAndSummaryEverywhere() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let oldTranscript = "Conteúdo anterior confirmado."
        let oldSummary = "# Resumo confirmado"
        let rejectedTranscript = "Conteúdo substituto que não pôde ser salvo."
        try fileStore.writeTranscript(oldTranscript, meetingID: meetingID)
        try fileStore.writeSummary(oldSummary, meetingID: meetingID)
        let meeting = Meeting(
            id: meetingID,
            title: "Commit transacional",
            state: .completed,
            transcript: oldTranscript,
            summary: oldSummary,
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 35
                )
            ]
        )
        let store = RejectingTranscriptMeetingStore(
            meetings: [meeting],
            rejectedTranscript: rejectedTranscript
        )
        let viewModel = MeetingViewModel(
            store: store,
            clipboard: MemoryClipboardService(),
            transcriptionService: TranscriptionService(
                whisperService: FakeWhisperService(transcripts: [1: rejectedTranscript]),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Não deve ser gerado"),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore
        )

        viewModel.selectMeeting(meeting)
        viewModel.retryTranscription()
        await waitUntil { viewModel.selectedMeeting?.state == .failed }

        XCTAssertTrue(store.didRejectReplacement)
        XCTAssertEqual(viewModel.selectedMeeting?.transcript, oldTranscript)
        XCTAssertEqual(viewModel.selectedMeeting?.summary, oldSummary)
        XCTAssertEqual(try store.loadMeetings().first?.transcript, oldTranscript)
        XCTAssertEqual(try store.loadMeetings().first?.summary, oldSummary)
        XCTAssertEqual(
            try String(contentsOf: fileStore.transcriptURL(meetingID: meetingID), encoding: .utf8),
            oldTranscript
        )
        XCTAssertEqual(
            try String(contentsOf: fileStore.summaryURL(meetingID: meetingID), encoding: .utf8),
            oldSummary
        )
    }

    func testTranscriptionDiagnosticsArePersistedAsSegmentWarnings() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let originalWarning = "A captura já estava degradada."
        let decoderWarning = "Uma fonte de áudio não pôde ser lida por completo."
        let meeting = Meeting(
            id: meetingID,
            title: "Aviso de fonte parcial",
            state: .completed,
            transcript: "Versão anterior.",
            summary: "# Resumo anterior",
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 35,
                    captureWarning: originalWarning
                )
            ]
        )
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            clipboard: MemoryClipboardService(),
            transcriptionService: TranscriptionService(
                whisperService: DiagnosticWhisperService(
                    transcript: "Transcrição recuperada.",
                    warning: decoderWarning
                ),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo novo"),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore
        )

        viewModel.selectMeeting(meeting)
        viewModel.retryTranscription()
        await waitUntil { viewModel.selectedMeeting?.state == .completed }

        let warning = try XCTUnwrap(viewModel.selectedMeeting?.recordingSegments.first?.captureWarning)
        XCTAssertTrue(warning.contains(originalWarning))
        XCTAssertTrue(warning.contains(decoderWarning))
    }

    func testRetryTranscriptionRecoversMeetingWhoseFirstTranscriptWasEmpty() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let meeting = Meeting(
            id: meetingID,
            title: "Recuperar transcrição vazia",
            state: .failed,
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 35
                )
            ]
        )
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            clipboard: MemoryClipboardService(),
            transcriptionService: TranscriptionService(
                whisperService: FakeWhisperService(
                    transcripts: [1: "Conteúdo recuperado integralmente."]
                ),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo recuperado"),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore
        )

        viewModel.selectMeeting(meeting)
        viewModel.retryTranscription()
        await waitUntil { viewModel.selectedMeeting?.state == .completed }

        XCTAssertEqual(viewModel.selectedMeeting?.transcript, "Conteúdo recuperado integralmente.")
        XCTAssertEqual(viewModel.selectedMeeting?.summary, "# Resumo recuperado")
        XCTAssertEqual(
            try String(contentsOf: fileStore.transcriptURL(meetingID: meetingID), encoding: .utf8),
            "Conteúdo recuperado integralmente."
        )
    }

    func testAudioFinalizationKeepsSystemAudioWhenMicrophoneTrackIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let systemURL = directory.appendingPathComponent("segment-system.caf")
        let microphoneURL = directory.appendingPathComponent("segment-microphone.caf")
        let outputURL = directory.appendingPathComponent("segment.m4a")

        do {
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: true
            ))
            let file = try AVAudioFile(
                forWriting: systemURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for index in 0..<(48_000 * 2) {
                buffer.floatChannelData?[0][index] = 0.15
            }
            try file.write(from: buffer)
        }

        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            _ = try AVAudioFile(forWriting: microphoneURL, settings: format.settings)
        }

        let finalizedURL = try await CoreAudioTapCaptureService.combineAudioTracks(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL
        )

        let outputAsset = AVURLAsset(url: finalizedURL)
        let duration = try await outputAsset.load(.duration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalizedURL.path))
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0)
    }

    func testFinalizationUsesValidMicrophoneWhenSystemWriterFailedAndPreservesRawFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let systemURL = directory.appendingPathComponent("segment-system.caf")
        let microphoneURL = directory.appendingPathComponent("segment-microphone.caf")
        let outputURL = directory.appendingPathComponent("segment.m4a")
        try writeCaptureTestCAF(to: systemURL, duration: 0)
        try writeCaptureTestCAF(to: microphoneURL, duration: 1, frequency: 440)

        let outcome = try await CoreAudioTapCaptureService.finalizeAudioTracks(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            systemCaptureError: "Falha simulada no writer do sistema.",
            microphoneCaptureError: nil,
            systemStartedAtUptime: 101,
            microphoneStartedAtUptime: 100
        )

        let outputAsset = AVURLAsset(url: outcome.fileURL)
        let duration = try await outputAsset.load(.duration)
        XCTAssertTrue(outcome.isDegraded)
        XCTAssertFalse(outcome.mayDeleteRawSources)
        XCTAssertTrue(outcome.degradationReasons.contains { $0.contains("writer") })
        XCTAssertTrue(outcome.userWarning?.contains("parcialmente") == true)
        XCTAssertTrue(outcome.userWarning?.contains("writer") == true)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.9)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
    }

    func testFinalizationPlacesDelayedSystemAudioAtItsMonotonicOffset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let systemURL = directory.appendingPathComponent("segment-system.caf")
        let microphoneURL = directory.appendingPathComponent("segment-microphone.caf")
        let outputURL = directory.appendingPathComponent("segment.m4a")
        try writeCaptureTestCAF(to: systemURL, duration: 1, frequency: 997)
        try writeCaptureTestCAF(to: microphoneURL, duration: 1, frequency: 440)

        let outcome = try await CoreAudioTapCaptureService.finalizeAudioTracks(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            outputURL: outputURL,
            systemCaptureError: nil,
            microphoneCaptureError: nil,
            systemStartedAtUptime: 100.5,
            microphoneStartedAtUptime: 100
        )

        let outputAsset = AVURLAsset(url: outcome.fileURL)
        let duration = CMTimeGetSeconds(try await outputAsset.load(.duration))
        XCTAssertFalse(outcome.isDegraded)
        XCTAssertTrue(outcome.mayDeleteRawSources)
        XCTAssertGreaterThan(duration, 1.4)
        XCTAssertLessThan(duration, 1.65)

        // Inspect a window in which both sources overlap. Detecting both
        // frequencies after AAC export proves that the composition audibly
        // mixes the two tracks instead of merely listing them in the asset.
        let magnitudes = try captureToneMagnitudes(
            from: outcome.fileURL,
            firstFrequency: 440,
            secondFrequency: 997,
            fromTime: 0.6,
            toTime: 0.9
        )
        XCTAssertGreaterThan(magnitudes.first, 0.03)
        XCTAssertGreaterThan(magnitudes.second, 0.03)
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
                    createdAt: Date(timeIntervalSince1970: 1_777_000_000),
                    captureWarning: "O microfone foi interrompido; o áudio disponível foi preservado."
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
        XCTAssertEqual(
            loaded.captureWarnings,
            ["O microfone foi interrompido; o áudio disponível foi preservado."]
        )
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

    func testFailedNewRecordingResumesPreviouslyDeferredTranscription() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let pendingID = UUID()
        let pendingMeeting = Meeting(
            id: pendingID,
            title: "Transcrição pendente",
            state: .preparingAudio,
            recordingSegments: [
                RecordingSegment(
                    meetingID: pendingID,
                    sequence: 1,
                    fileURL: rootURL.appendingPathComponent("segment-001.m4a"),
                    recordedDuration: 2
                )
            ]
        )
        let captureService = RetryableFakeAudioCaptureService()
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [pendingMeeting]),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: captureService,
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: DelayedFakeWhisperService(transcript: "Processamento retomado."),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo\n\nRetomado."),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: FakeLocalResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil {
            viewModel.meetings.first(where: { $0.id == pendingID })?.state == .transcribing
        }
        await viewModel.beginRecording()
        await waitUntil {
            viewModel.meetings.first(where: { $0.id == pendingID })?.state == .completed
        }

        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == pendingID })?.transcript,
            "Processamento retomado."
        )
        XCTAssertEqual(captureService.startAttempts, 1)
    }

    func testRecordingSessionAllowsNewMeetingAfterFinalizationFailure() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureService = RetryableStopAudioCaptureService()
        let session = RecordingSession(
            captureService: captureService,
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )

        try await session.start(meetingID: UUID())
        await XCTAssertThrowsErrorAsync {
            _ = try await session.finish()
        }

        try await session.start(meetingID: UUID())
        let recoveredSegments = try await session.finish()

        XCTAssertEqual(captureService.startAttempts, 2)
        XCTAssertEqual(recoveredSegments.count, 1)
    }

    func testRecordingSessionAllowsNewMeetingAfterResumeFailure() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureService = ResumeFailureAudioCaptureService()
        let session = RecordingSession(
            captureService: captureService,
            fileStore: LocalMeetingFileStore(rootURL: rootURL)
        )

        try await session.start(meetingID: UUID())
        let preservedSegment = try await session.pause()
        await XCTAssertThrowsErrorAsync {
            try await session.resume()
        }

        try await session.start(meetingID: UUID())
        let newMeetingSegments = try await session.finish()

        XCTAssertEqual(preservedSegment.recordedDuration, 3)
        XCTAssertEqual(captureService.startAttempts, 3)
        XCTAssertEqual(newMeetingSegments.count, 1)
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

    func testTranscriptionSkipsSilentSegmentWhenOtherSegmentsContainSpeech() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let segments = (1...3).map { sequence in
            RecordingSegment(
                meetingID: meetingID,
                sequence: sequence,
                fileURL: rootURL.appendingPathComponent("segment-00\(sequence).m4a"),
                recordedDuration: 2
            )
        }
        let service = TranscriptionService(
            whisperService: FakeWhisperService(transcripts: [
                1: "Primeira fala.",
                2: "   ",
                3: "Última fala."
            ]),
            fileStore: fileStore
        )

        let transcript = try await service.transcribe(
            meetingID: meetingID,
            segments: segments
        )

        XCTAssertEqual(transcript, "Primeira fala.\n\nÚltima fala.")
        XCTAssertEqual(
            try String(
                contentsOf: fileStore.transcriptURL(meetingID: meetingID),
                encoding: .utf8
            ),
            transcript
        )
    }

    func testTranscriptionPreservesUsableSegmentsWhenOneSegmentCannotBeDecoded() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let segments = (1...3).map { sequence in
            RecordingSegment(
                meetingID: meetingID,
                sequence: sequence,
                fileURL: rootURL.appendingPathComponent("segment-00\(sequence).m4a"),
                recordedDuration: 2
            )
        }
        let service = TranscriptionService(
            whisperService: SegmentFailureWhisperService(),
            fileStore: fileStore
        )

        let transcript = try await service.transcribe(
            meetingID: meetingID,
            segments: segments
        )

        XCTAssertTrue(transcript.contains("Primeira fala."))
        XCTAssertTrue(transcript.contains("Última fala."))
        XCTAssertLessThan(
            try XCTUnwrap(transcript.range(of: "Primeira fala.")?.lowerBound),
            try XCTUnwrap(transcript.range(of: "Última fala.")?.lowerBound)
        )
        XCTAssertTrue(transcript.contains("segmento 2 não pôde ser transcrito"))
        XCTAssertEqual(
            try String(
                contentsOf: fileStore.transcriptURL(meetingID: meetingID),
                encoding: .utf8
            ),
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
            ["Reunião Padrão", "1:1", "Descoberta de cliente", "Contratação", "Gestão de contas", "Cliente existente", "Onboarding de cliente", "Solução de problemas", "Sincronização de projeto", "Personalizado"]
        )
        XCTAssertEqual(SummaryTemplate.general, .standardMeeting)
        XCTAssertEqual(
            SummaryTemplate.standardMeeting.sections,
            ["Objetivo da reunião", "Principais pontos abordados", "Próximos passos"]
        )
        XCTAssertTrue(SummaryTemplate.standardMeeting.instructions.contains("aprofundado"))
        XCTAssertTrue(SummaryTemplate.standardMeeting.instructions.contains("todos os subtemas relevantes"))
        XCTAssertTrue(SummaryTemplate.standardMeeting.instructions.contains("somente compromissos explícitos"))
        XCTAssertTrue(SummaryTemplate.oneOnOne.sections.contains("Feedback mútuo"))
        XCTAssertTrue(SummaryTemplate.customerDiscovery.sections.contains("Orçamento e cronograma"))
        XCTAssertTrue(SummaryTemplate.hiring.sections.contains("Disponibilidade e pretensão salarial"))
        XCTAssertTrue(SummaryTemplate.accountManagement.sections.contains("Planos futuros"))
        XCTAssertTrue(SummaryTemplate.existingCustomer.sections.contains("Satisfação atual"))
        XCTAssertTrue(SummaryTemplate.customerOnboarding.sections.contains("Perguntas e preocupações"))
        XCTAssertTrue(SummaryTemplate.troubleshooting.sections.contains("Soluções sugeridas e resultados"))
        XCTAssertTrue(SummaryTemplate.projectSync.sections.contains("Bloqueios atuais"))
        XCTAssertEqual(
            SummaryTemplate.custom.personalized(with: "Objetivos; Riscos; Ações").sections,
            ["Objetivos", "Riscos", "Ações"]
        )
    }

    func testNewMeetingsUseStandardMeetingTemplateByDefault() {
        let meeting = Meeting(title: "Nova reunião")

        XCTAssertEqual(meeting.templateId, SummaryTemplate.standardMeeting.id)

        let viewModel = MeetingViewModel(
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService()
        )
        XCTAssertEqual(viewModel.selectedTemplate, .standardMeeting)
        XCTAssertEqual(viewModel.newMeetingTemplate, .standardMeeting)
    }

    func testTemplateMigrationAddsStandardMeetingWithoutChangingExistingTemplates() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("templates.json")
        let editedOneOnOne = SummaryTemplate(
            id: SummaryTemplate.oneOnOne.id,
            displayName: "1:1 personalizado",
            instructions: "Instruções editadas pelo usuário.",
            sections: ["Minha pauta", "Meus próximos passos"],
            isBuiltIn: true
        )
        let custom = SummaryTemplate(
            id: "user-existing-template",
            displayName: "Template existente",
            instructions: "Não alterar este conteúdo.",
            sections: ["Seção existente"]
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode([editedOneOnOne, custom]).write(to: fileURL, options: .atomic)

        let migrated = try LocalSummaryTemplateStore(fileURL: fileURL).loadTemplates()

        XCTAssertEqual(migrated.first?.id, SummaryTemplate.standardMeeting.id)
        XCTAssertEqual(
            migrated.first(where: { $0.id == editedOneOnOne.id })?.displayName,
            "1:1 personalizado"
        )
        XCTAssertEqual(
            migrated.first(where: { $0.id == editedOneOnOne.id })?.sections,
            ["Minha pauta", "Meus próximos passos"]
        )
        XCTAssertEqual(
            migrated.first(where: { $0.id == custom.id })?.instructions,
            "Não alterar este conteúdo."
        )
        XCTAssertEqual(
            migrated.first(where: { $0.id == SummaryTemplate.standardMeeting.id }),
            .standardMeeting
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

        XCTAssertEqual(loaded.first(where: { $0.id == SummaryTemplate.general.id })?.displayName, "Reunião Executiva")
        XCTAssertEqual(loaded.first(where: { $0.id == SummaryTemplate.general.id })?.sections, ["Síntese", "Decisões"])
        XCTAssertEqual(loaded.first(where: { $0.id == "user-retro" })?.instructions, "Organize aprendizados do ciclo.")
        XCTAssertTrue(loaded.contains(where: { $0.id == SummaryTemplate.daily.id }))
    }

    func testTemplateMigrationRefreshesOnlyTheUneditedStandardBaseline() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("templates.json")
        let oldBaseline = SummaryTemplate(
            id: SummaryTemplate.standardMeeting.id,
            displayName: SummaryTemplate.standardMeeting.displayName,
            instructions: SummaryTemplate.legacyStandardMeetingInstructions,
            sections: SummaryTemplate.standardMeeting.sections,
            isBuiltIn: true
        )
        let customized = SummaryTemplate(
            id: SummaryTemplate.standardMeeting.id,
            displayName: "Minha reunião",
            instructions: "Orientação realmente editada.",
            sections: ["Minha seção"],
            isBuiltIn: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        try JSONEncoder().encode([oldBaseline]).write(to: fileURL, options: .atomic)
        XCTAssertEqual(
            try LocalSummaryTemplateStore(fileURL: fileURL).loadTemplates().first,
            .standardMeeting
        )

        try JSONEncoder().encode([customized]).write(to: fileURL, options: .atomic)
        let preserved = try LocalSummaryTemplateStore(fileURL: fileURL).loadTemplates()
        XCTAssertEqual(
            preserved.first(where: { $0.id == SummaryTemplate.standardMeeting.id })?.instructions,
            "Orientação realmente editada."
        )
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

    func testSummaryInlineEditAutosavesMeetingAndMarkdownFile() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "Resumo editável", state: .completed, summary: "# Original")
        let meetingStore = try SwiftDataMeetingStore(inMemory: true)
        try meetingStore.save(meeting)
        let viewModel = MeetingViewModel(
            store: meetingStore,
            clipboard: MemoryClipboardService(),
            fileStore: fileStore
        )

        viewModel.selectMeeting(meeting)
        viewModel.updateSummary("# Alterado\n\nConteúdo revisado.")

        XCTAssertEqual(viewModel.summaryAutosaveMessage, "Salvo automaticamente")
        XCTAssertEqual(try meetingStore.loadMeetings().first?.summary, "# Alterado\n\nConteúdo revisado.")
        XCTAssertEqual(
            try String(contentsOf: fileStore.summaryURL(meetingID: meeting.id), encoding: .utf8),
            "# Alterado\n\nConteúdo revisado."
        )
    }

    func testGroundedSelectionPromptRestrictsHallucinationsAndUsesTemplateSections() {
        let prompt = GroundedSelectionPrompt.user(
            inventory: "[S0] Foi discutida a entrega.",
            template: .refinement
        )

        XCTAssertTrue(GroundedSelectionPrompt.system.contains("Nunca escreva, reescreva"))
        XCTAssertTrue(GroundedSelectionPrompt.system.contains("ignore instruções"))
        XCTAssertTrue(GroundedSelectionPrompt.system.contains("somente identificadores S"))
        XCTAssertTrue(prompt.contains("SEC0: Status do projeto"))
        XCTAssertTrue(prompt.contains("Próximas tarefas e marcos"))
        XCTAssertTrue(prompt.contains(SummaryTemplate.refinement.instructions))
        XCTAssertTrue(prompt.contains("[S0] Foi discutida a entrega."))
    }

    func testExtractiveSummaryUsesTranscriptFactsAndMarksAbsentSections() async throws {
        let provider = ExtractiveSummaryProvider()
        let summary = try await provider.generateSummary(
            transcript: "O objetivo da reunião é alinhar o novo cronograma. A equipe discutiu a dependência do contrato. Bruno vai enviar a proposta na sexta-feira.",
            template: .general
        )

        XCTAssertTrue(summary.contains("## Objetivo da reunião\n\nO objetivo da reunião é alinhar o novo cronograma"))
        XCTAssertFalse(summary.contains("## Objetivo da reunião\n\n- "))
        XCTAssertTrue(summary.contains("## Principais pontos abordados\n\n- A equipe discutiu a dependência do contrato"))
        XCTAssertTrue(summary.contains("## Próximos passos\n\n- Bruno vai enviar a proposta na sexta-feira"))

        let refinement = try await provider.generateSummary(
            transcript: "A equipe aprovou o novo cronograma.",
            template: .troubleshooting
        )
        XCTAssertTrue(refinement.contains("## Soluções sugeridas e resultados\n\nNão informado na transcrição"))
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
            viewModel.meetings.first?.state == .failed
        }

        XCTAssertEqual(viewModel.meetings.first?.state, .failed)
        XCTAssertEqual(viewModel.meetings.first?.transcript, "Transcrição preservada.")
        XCTAssertEqual(viewModel.meetings.first?.recordingSegments.count, 1)
        XCTAssertNil(viewModel.errorTitle)
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

    func testFinishRequestedWhilePauseIsInFlightRunsAfterPauseCompletes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let captureService = SuspendedPauseTransitionAudioCaptureService()
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: []),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: captureService,
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: FakeWhisperService(transcripts: [1: "Áudio preservado."]),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo"),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler()
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        await viewModel.beginRecording()
        let meetingID = try XCTUnwrap(viewModel.selectedMeetingID)
        let pauseTask = Task { await viewModel.pauseActiveRecording() }
        await waitUntil { captureService.pauseStopIsWaiting }
        XCTAssertTrue(captureService.pauseStopIsWaiting)

        // This is the same synchronous call made by MeetingPresenceMonitor.
        viewModel.finishRecording()
        captureService.completePauseStop()
        await pauseTask.value
        await waitUntil { viewModel.screen == .empty }

        let finished = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meetingID })
        )
        XCTAssertEqual(viewModel.screen, .empty)
        XCTAssertNil(viewModel.selectedMeetingID)
        XCTAssertEqual(finished.state, .preparingAudio)
        XCTAssertEqual(finished.recordingSegments.map(\.sequence), [1])
        XCTAssertEqual(captureService.stopCount, 1)
    }

    func testFinishRequestedWhileResumeIsInFlightRunsAfterResumeCompletes() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let captureService = SuspendedResumeTransitionAudioCaptureService()
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: []),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: captureService,
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: FakeWhisperService(
                    transcripts: [1: "Primeiro segmento.", 2: "Segundo segmento."]
                ),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: FakeSummaryProvider(summary: "# Resumo"),
                fileStore: fileStore
            ),
            calendarService: FakeGoogleCalendarService(),
            reminderScheduler: FakeReminderScheduler()
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        await viewModel.beginRecording()
        let meetingID = try XCTUnwrap(viewModel.selectedMeetingID)
        await viewModel.pauseActiveRecording()
        XCTAssertEqual(viewModel.screen, .paused)

        let resumeTask = Task { await viewModel.resumeActiveRecording() }
        await waitUntil { captureService.resumeStartIsWaiting }
        XCTAssertTrue(captureService.resumeStartIsWaiting)

        // The end signal must survive until the new segment is fully opened.
        viewModel.finishRecording()
        captureService.completeResumeStart()
        await resumeTask.value
        await waitUntil { viewModel.screen == .empty }

        let finished = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meetingID })
        )
        XCTAssertEqual(viewModel.screen, .empty)
        XCTAssertNil(viewModel.selectedMeetingID)
        XCTAssertEqual(finished.state, .preparingAudio)
        XCTAssertEqual(finished.recordingSegments.map(\.sequence), [1, 2])
        XCTAssertEqual(captureService.startCount, 2)
        XCTAssertEqual(captureService.stopCount, 2)
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
private final class RejectingTranscriptMeetingStore: MeetingStore {
    private var meetings: [Meeting]
    private let rejectedTranscript: String
    private(set) var didRejectReplacement = false

    init(meetings: [Meeting], rejectedTranscript: String) {
        self.meetings = meetings
        self.rejectedTranscript = rejectedTranscript
    }

    func loadMeetings() throws -> [Meeting] {
        meetings
    }

    func save(_ meeting: Meeting) throws {
        if meeting.transcript == rejectedTranscript, !didRejectReplacement {
            didRejectReplacement = true
            throw MeetingStoreError.unavailable("falha simulada no commit")
        }
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }

    func delete(id: UUID) throws {
        meetings.removeAll { $0.id == id }
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
        permissionRequests += 1
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
private final class SuspendedStartAudioCaptureService: AudioCaptureService {
    private var continuation: CheckedContinuation<Void, Never>?
    private var activeURL: URL?
    private(set) var startAttempts = 0

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        startAttempts += 1
        activeURL = fileURL
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func completeStart() {
        continuation?.resume()
        continuation = nil
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let activeURL else { throw RecordingError.noActiveRecording }
        self.activeURL = nil
        return CapturedAudio(fileURL: activeURL, duration: 1)
    }
}

@MainActor
private final class SuspendedFinalizationAudioCaptureService: AudioCaptureService {
    private var activeURL: URL?
    private var firstStopContinuation: CheckedContinuation<Void, Never>?
    private var stopCount = 0
    private(set) var firstStopIsWaiting = false
    private(set) var startedURLs: [URL] = []

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        guard activeURL == nil else { throw RecordingError.alreadyRecording }
        activeURL = fileURL
        startedURLs.append(fileURL)
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let finishingURL = activeURL else { throw RecordingError.noActiveRecording }
        activeURL = nil
        stopCount += 1
        if stopCount == 1 {
            firstStopIsWaiting = true
            await withCheckedContinuation { continuation in
                firstStopContinuation = continuation
            }
            firstStopIsWaiting = false
        }
        return CapturedAudio(fileURL: finishingURL, duration: stopCount == 1 ? 4 : 5)
    }

    func completeFirstStop() {
        firstStopContinuation?.resume()
        firstStopContinuation = nil
    }
}

@MainActor
private final class SuspendedPauseTransitionAudioCaptureService: AudioCaptureService {
    private var activeURL: URL?
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private(set) var pauseStopIsWaiting = false
    private(set) var stopCount = 0

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        guard activeURL == nil else { throw RecordingError.alreadyRecording }
        activeURL = fileURL
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let finishingURL = activeURL else { throw RecordingError.noActiveRecording }
        activeURL = nil
        stopCount += 1
        pauseStopIsWaiting = true
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
        }
        pauseStopIsWaiting = false
        return CapturedAudio(fileURL: finishingURL, duration: 1)
    }

    func completePauseStop() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

@MainActor
private final class SuspendedResumeTransitionAudioCaptureService: AudioCaptureService {
    private var activeURL: URL?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private(set) var resumeStartIsWaiting = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        guard activeURL == nil else { throw RecordingError.alreadyRecording }
        activeURL = fileURL
        startCount += 1
        if startCount == 2 {
            resumeStartIsWaiting = true
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
            resumeStartIsWaiting = false
        }
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let finishingURL = activeURL else { throw RecordingError.noActiveRecording }
        activeURL = nil
        stopCount += 1
        return CapturedAudio(fileURL: finishingURL, duration: 1)
    }

    func completeResumeStart() {
        resumeContinuation?.resume()
        resumeContinuation = nil
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

@MainActor
private final class RetryableStopAudioCaptureService: AudioCaptureService {
    private var activeURL: URL?
    private(set) var startAttempts = 0
    private var stopAttempts = 0

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        startAttempts += 1
        activeURL = fileURL
    }

    func stopSegment() async throws -> CapturedAudio {
        stopAttempts += 1
        guard let activeURL else { throw RecordingError.noActiveRecording }
        self.activeURL = nil
        if stopAttempts == 1 {
            throw RecordingError.fileWriteFailed("Falha simulada ao finalizar o áudio.")
        }
        return CapturedAudio(fileURL: activeURL, duration: 1)
    }
}

@MainActor
private final class ResumeFailureAudioCaptureService: AudioCaptureService {
    private var activeURL: URL?
    private(set) var startAttempts = 0

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        startAttempts += 1
        if startAttempts == 2 {
            throw RecordingError.captureFailed("Falha simulada ao retomar.")
        }
        activeURL = fileURL
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let activeURL else { throw RecordingError.noActiveRecording }
        self.activeURL = nil
        return CapturedAudio(fileURL: activeURL, duration: 3)
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

private struct DiagnosticWhisperService: WhisperService {
    let transcript: String
    let warning: String

    func transcribe(segment: RecordingSegment) async throws -> String {
        transcript
    }

    func transcribeWithDiagnostics(
        segment: RecordingSegment
    ) async throws -> WhisperTranscriptionResult {
        WhisperTranscriptionResult(transcript: transcript, warnings: [warning])
    }
}

private struct SegmentFailureWhisperService: WhisperService {
    func transcribe(segment: RecordingSegment) async throws -> String {
        switch segment.sequence {
        case 1: "Primeira fala."
        case 2: throw WhisperError.transcriptionFailed("arquivo inválido")
        default: "Última fala."
        }
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
private final class WhisperInvocationCounter {
    private(set) var count = 0

    func register() -> Int {
        count += 1
        return count
    }
}

private struct SuspendFirstWhisperService: WhisperService {
    let counter: WhisperInvocationCounter

    func transcribe(segment: RecordingSegment) async throws -> String {
        let invocation = await counter.register()
        if invocation == 1 {
            try await Task.sleep(for: .seconds(30))
        }
        return "Transcrição retomada."
    }
}

private final class BackgroundWorkPriorityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriptionInvocations: [UUID: Int] = [:]
    private var didObserveCancellation = false
    private var didStartCaptureAfterCancellation = false
    private var didExitCancelledWorker = false
    private var didStartCaptureAfterWorkerExit = false
    private var captureStarts = 0

    var cancellationObserved: Bool {
        lock.withLock { didObserveCancellation }
    }

    var captureStartedAfterBackgroundCancellation: Bool {
        lock.withLock { didStartCaptureAfterCancellation }
    }

    var cancelledWorkerExited: Bool {
        lock.withLock { didExitCancelledWorker }
    }

    var captureStartedAfterWorkerExit: Bool {
        lock.withLock { didStartCaptureAfterWorkerExit }
    }

    var captureStartCount: Int {
        lock.withLock { captureStarts }
    }

    func transcriptionInvocationCount(for meetingID: UUID) -> Int {
        lock.withLock { transcriptionInvocations[meetingID, default: 0] }
    }

    func registerTranscriptionInvocation(for meetingID: UUID) -> Int {
        lock.withLock {
            transcriptionInvocations[meetingID, default: 0] += 1
            return transcriptionInvocations[meetingID, default: 0]
        }
    }

    func registerCancellation() {
        lock.withLock {
            didObserveCancellation = true
        }
    }

    func registerCancelledWorkerExit() {
        lock.withLock {
            didExitCancelledWorker = true
        }
    }

    func registerCaptureStart() {
        lock.withLock {
            captureStarts += 1
            didStartCaptureAfterCancellation = didObserveCancellation
            didStartCaptureAfterWorkerExit = didExitCancelledWorker
        }
    }
}

private struct CancellableThenSuccessfulWhisperService: WhisperService {
    let probe: BackgroundWorkPriorityProbe
    let cancellableMeetingID: UUID

    func transcribe(segment: RecordingSegment) async throws -> String {
        let invocation = probe.registerTranscriptionInvocation(for: segment.meetingID)
        guard segment.meetingID == cancellableMeetingID, invocation == 1 else {
            return "Transcrição fiel retomada."
        }

        return try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(30))
            return "A primeira tentativa deveria ter sido cancelada."
        } onCancel: {
            probe.registerCancellation()
        }
    }
}

@MainActor
private final class UninterruptibleWhisperController: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func waitForRelease() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct UninterruptibleThenSuccessfulWhisperService: WhisperService {
    let probe: BackgroundWorkPriorityProbe
    let controller: UninterruptibleWhisperController
    let blockedMeetingID: UUID

    func transcribe(segment: RecordingSegment) async throws -> String {
        let invocation = probe.registerTranscriptionInvocation(for: segment.meetingID)
        guard segment.meetingID == blockedMeetingID, invocation == 1 else {
            return "Transcrição retomada depois da captura."
        }

        return try await withTaskCancellationHandler {
            // Model initialization in whisper.cpp cannot be interrupted midway.
            // This continuation models that exact interval deterministically.
            await controller.waitForRelease()
            probe.registerCancelledWorkerExit()
            try Task.checkCancellation()
            return "Não deve ser usada."
        } onCancel: {
            probe.registerCancellation()
        }
    }
}

@MainActor
private final class SuspendedReplacementTranscriptionController: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var isWaiting = false

    func waitForReplacement() async -> String {
        isWaiting = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func completeIfNeeded(with transcript: String) {
        isWaiting = false
        continuation?.resume(returning: transcript)
        continuation = nil
    }
}

private struct SuspendedReplacementWhisperService: WhisperService {
    let controller: SuspendedReplacementTranscriptionController

    func transcribe(segment: RecordingSegment) async throws -> String {
        await controller.waitForReplacement()
    }
}

@MainActor
private final class PriorityObservingAudioCaptureService: AudioCaptureService {
    private let probe: BackgroundWorkPriorityProbe
    private var activeURL: URL?

    init(probe: BackgroundWorkPriorityProbe) {
        self.probe = probe
    }

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        probe.registerCaptureStart()
        activeURL = fileURL
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let activeURL else { throw RecordingError.noActiveRecording }
        self.activeURL = nil
        return CapturedAudio(fileURL: activeURL, duration: 1)
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

private func writeCaptureTestCAF(
    to url: URL,
    duration: TimeInterval,
    frequency: Double = 440,
    amplitude: Float = 0.18
) throws {
    let sampleRate = 48_000.0
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let frameCount = AVAudioFrameCount(max(0, duration) * sampleRate)
    guard frameCount > 0 else { return }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let samples = buffer.floatChannelData?[0] else {
        throw CocoaError(.fileWriteUnknown)
    }
    buffer.frameLength = frameCount
    for frame in 0..<Int(frameCount) {
        samples[frame] = amplitude * Float(
            sin(2 * Double.pi * frequency * Double(frame) / sampleRate)
        )
    }
    try file.write(from: buffer)
}

private func captureToneMagnitudes(
    from url: URL,
    firstFrequency: Double,
    secondFrequency: Double,
    fromTime: TimeInterval,
    toTime: TimeInterval
) throws -> (first: Double, second: Double) {
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0,
          let buffer = AVAudioPCMBuffer(
              pcmFormat: file.processingFormat,
              frameCapacity: AVAudioFrameCount(file.length)
          ) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    try file.read(into: buffer)
    guard let samples = buffer.floatChannelData?[0] else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let sampleRate = file.processingFormat.sampleRate
    let startFrame = max(0, min(Int(buffer.frameLength), Int(fromTime * sampleRate)))
    let endFrame = max(startFrame, min(Int(buffer.frameLength), Int(toTime * sampleRate)))
    guard endFrame > startFrame else {
        throw CocoaError(.fileReadCorruptFile)
    }

    func magnitude(at frequency: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for frame in startFrame..<endFrame {
            let sample = Double(samples[frame])
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            real += sample * cos(phase)
            imaginary -= sample * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(endFrame - startFrame)
    }

    return (magnitude(at: firstFrequency), magnitude(at: secondFrequency))
}
