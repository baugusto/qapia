@preconcurrency import AVFoundation
import XCTest
@testable import QapiaCore

@MainActor
final class InterruptedRecordingRecoveryTests: XCTestCase {
    func testReopenedStorePreservesInterruptedRecordingStatesForRecovery() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = rootURL.appendingPathComponent("Persistence/QAPia.store")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = Meeting(title: "Gravação interrompida", state: .recording)
        let paused = Meeting(title: "Pausa interrompida", state: .paused)
        do {
            let store = try SwiftDataMeetingStore(storeURL: storeURL)
            try store.save(recording)
            try store.save(paused)
        }

        let reopenedStore = try SwiftDataMeetingStore(storeURL: storeURL)
        let recovered = try reopenedStore.loadMeetings()

        XCTAssertEqual(recovered.first(where: { $0.id == recording.id })?.state, .recording)
        XCTAssertEqual(recovered.first(where: { $0.id == paused.id })?.state, .paused)
    }

    func testViewModelRecoversRealCAFBeforeResumingProcessing() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = rootURL.appendingPathComponent("Persistence/QAPia.store")
        let meetingsURL = rootURL.appendingPathComponent("Meetings", isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: meetingsURL)
        let meeting = Meeting(title: "Áudio interrompido", state: .recording)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let finalURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = finalURL.deletingPathExtension()
            .appendingPathExtension("caf")
            .deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        try writeShortCAF(to: systemURL)

        do {
            let store = try SwiftDataMeetingStore(storeURL: storeURL)
            try store.save(meeting)
        }

        let reopenedStore = try SwiftDataMeetingStore(storeURL: storeURL)
        XCTAssertEqual(try reopenedStore.loadMeetings().first?.state, .recording)

        let recordingSession = RecordingSession(
            captureService: RecoveryNoopAudioCaptureService(),
            fileStore: fileStore
        )
        let viewModel = MeetingViewModel(
            store: reopenedStore,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: recordingSession,
            transcriptionService: TranscriptionService(
                whisperService: RecoveryAudioValidatingWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: RecoverySummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: RecoveryCalendarService(),
            reminderScheduler: RecoveryReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: RecoveryResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 8) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.state == .completed
        }

        let recoveredMeeting = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        let recoveredSegment = try XCTUnwrap(recoveredMeeting.recordingSegments.first)
        let expectedWarning = "Recuperação parcial: o áudio do microfone estava ausente ou corrompido; somente o áudio do sistema foi preservado."
        XCTAssertEqual(recoveredMeeting.state, .completed)
        XCTAssertEqual(recoveredMeeting.transcript, "Áudio recuperado e validado.")
        XCTAssertEqual(recoveredMeeting.summary, "# Resumo\n\nGravação recuperada.")
        XCTAssertEqual(recoveredMeeting.recordingSegments.count, 1)
        XCTAssertEqual(recoveredSegment.captureWarning, expectedWarning)
        XCTAssertEqual(recoveredMeeting.captureWarnings, [expectedWarning])
        XCTAssertGreaterThan(recoveredMeeting.recordedDuration, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredSegment.fileURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: systemURL.path),
            "Uma recuperação degradada deve preservar o CAF bruto disponível."
        )

        let asset = AVURLAsset(url: recoveredSegment.fileURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioDuration = try await asset.load(.duration)
        XCTAssertFalse(audioTracks.isEmpty)
        XCTAssertGreaterThan(CMTimeGetSeconds(audioDuration), 0)

        let persisted = try XCTUnwrap(
            reopenedStore.loadMeetings().first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(persisted.state, .completed)
        XCTAssertEqual(persisted.recordingSegments.count, 1)
        XCTAssertEqual(persisted.recordingSegments.first?.captureWarning, expectedWarning)
        XCTAssertEqual(persisted.captureWarnings, [expectedWarning])
        XCTAssertFalse(persisted.transcript.isEmpty)
    }

    func testRecoveryRevalidatesMeetingByUUIDWhenANewRecordingIsInsertedDuringValidation() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let interrupted = Meeting(title: "Interrompida", state: .recording)
        let interruptedOutputURL = try fileStore.makeSegmentURL(
            meetingID: interrupted.id,
            sequence: 1
        )
        try writeShortCAF(to: interruptedOutputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recoveryOperations = SuspendedValidationRecoveryOperations(
            suspendedURL: interruptedOutputURL,
            duration: 0.25
        )
        let captureService = RecoveryImmediateAudioCaptureService()
        let viewModel = makeViewModel(
            meetings: [interrupted],
            fileStore: fileStore,
            captureService: captureService
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in
                await recoveryOperations.validDuration(at: url)
            },
            combineAudioTracks: {
                systemURL, microphoneURL, outputURL, _, _, _, _ in
                try await recoveryOperations.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL
                )
            }
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) { recoveryOperations.isWaiting }
        XCTAssertTrue(recoveryOperations.isWaiting)

        await viewModel.beginRecording()
        let newMeetingID = try XCTUnwrap(viewModel.selectedMeetingID)
        XCTAssertNotEqual(newMeetingID, interrupted.id)
        XCTAssertEqual(viewModel.screen, .recording)

        recoveryOperations.resumeValidation()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == interrupted.id })?.state == .preparingAudio
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == interrupted.id })
        )
        let active = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == newMeetingID })
        )
        XCTAssertEqual(recovered.recordingSegments.count, 1)
        XCTAssertEqual(recovered.recordingSegments.first?.meetingID, interrupted.id)
        XCTAssertEqual(recovered.recordingSegments.first?.fileURL, interruptedOutputURL)
        XCTAssertEqual(active.state, .recording)
        XCTAssertTrue(active.recordingSegments.isEmpty)
        XCTAssertEqual(viewModel.meetings.filter { $0.state == .recording }.map(\.id), [newMeetingID])

        await viewModel.finishActiveRecording()
        XCTAssertEqual(captureService.stopCount, 1)
        XCTAssertEqual(viewModel.screen, .empty)
    }

    func testRecoveryUsesPersistedTwoSecondSourceOffsetAfterStoreRelaunch() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = rootURL.appendingPathComponent("Persistence/QAPia.store")
        let fileStore = LocalMeetingFileStore(
            rootURL: rootURL.appendingPathComponent("Meetings", isDirectory: true)
        )
        let meeting = Meeting(title: "Sincronização interrompida", state: .recording)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        let microphoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-microphone.caf")
        try writeShortCAF(to: microphoneURL)
        try writeShortCAF(to: systemURL)
        var manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            captureStartedAt: Date(timeIntervalSince1970: 1_777_000_000),
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            systemStartedAtUptime: 102,
            observedDuration: 2.25,
            phase: .recording
        )
        manifest.lastObservedAt = Date(timeIntervalSince1970: 1_777_000_002.25)
        try manifest.writeAtomically(for: outputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        do {
            let store = try SwiftDataMeetingStore(storeURL: storeURL)
            try store.save(meeting)
        }
        let reopenedStore = try SwiftDataMeetingStore(storeURL: storeURL)
        let recoveryOperations = RecoveryOffsetCapturingOperations(
            outputURL: outputURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL
        )
        let viewModel = MeetingViewModel(
            store: reopenedStore,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: RecoveryNoopAudioCaptureService(),
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: RecoveryStaticWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: RecoverySummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: RecoveryCalendarService(),
            reminderScheduler: RecoveryReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: RecoveryResourcePreparer()
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in
                await recoveryOperations.validDuration(at: url)
            },
            combineAudioTracks: {
                systemURL,
                microphoneURL,
                outputURL,
                systemOffset,
                microphoneOffset,
                includeSystem,
                includeMicrophone in
                try await recoveryOperations.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL,
                    systemOffset: systemOffset,
                    microphoneOffset: microphoneOffset,
                    includeSystem: includeSystem,
                    includeMicrophone: includeMicrophone
                )
            }
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) { recoveryOperations.combineCallCount == 1 }

        XCTAssertEqual(recoveryOperations.systemOffset, 2, accuracy: 0.000_1)
        XCTAssertEqual(recoveryOperations.microphoneOffset, 0, accuracy: 0.000_1)
        XCTAssertTrue(recoveryOperations.includedSystem)
        XCTAssertTrue(recoveryOperations.includedMicrophone)
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.recordingSegments.count == 1
        }
        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(recovered.recordingSegments.first?.fileURL, outputURL)
        XCTAssertTrue(recovered.captureWarnings.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: AudioCaptureRecoveryManifest.manifestURL(for: outputURL).path
            )
        )
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.state == .completed
        }
        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == meeting.id })?.state,
            .completed
        )
    }

    func testRecoveryEnumeratesAndTranscribesAllOrphanSegmentsInSequenceOrder() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = rootURL.appendingPathComponent("Persistence/QAPia.store")
        let fileStore = LocalMeetingFileStore(
            rootURL: rootURL.appendingPathComponent("Meetings", isDirectory: true)
        )
        let meeting = Meeting(title: "Três segmentos interrompidos", state: .recording)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstOutputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let firstLegacyURL = firstOutputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001.caf")
        try writeShortCAF(to: firstLegacyURL)

        let secondOutputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 2)
        let secondSystemURL = secondOutputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-002-system.caf")
        try writeShortCAF(to: secondSystemURL)

        let thirdOutputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 3)
        let thirdLegacyURL = thirdOutputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-003.caf")
        try writeShortCAF(to: thirdLegacyURL)

        do {
            let store = try SwiftDataMeetingStore(storeURL: storeURL)
            try store.save(meeting)
        }
        let reopenedStore = try SwiftDataMeetingStore(storeURL: storeURL)
        let viewModel = MeetingViewModel(
            store: reopenedStore,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: RecoveryNoopAudioCaptureService(),
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: RecoverySequencedWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: RecoverySummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: RecoveryCalendarService(),
            reminderScheduler: RecoveryReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: RecoveryResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 8) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.state == .completed
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(recovered.state, .completed)
        XCTAssertEqual(recovered.recordingSegments.map(\.sequence), [1, 2, 3])
        XCTAssertTrue(recovered.recordingSegments.allSatisfy { $0.recordedDuration > 0 })
        let firstRange = try XCTUnwrap(recovered.transcript.range(of: "Segmento 1"))
        let secondRange = try XCTUnwrap(recovered.transcript.range(of: "Segmento 2"))
        let thirdRange = try XCTUnwrap(recovered.transcript.range(of: "Segmento 3"))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
        XCTAssertLessThan(secondRange.lowerBound, thirdRange.lowerBound)

        let persisted = try XCTUnwrap(
            reopenedStore.loadMeetings().first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(persisted.recordingSegments.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(persisted.transcript, recovered.transcript)
    }

    func testRecoveryRebuildsDecodableButTruncatedOutputAndPreservesRawSources() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "M4A truncado", state: .recording)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        let microphoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-microphone.caf")
        try Data("final-curto".utf8).write(to: outputURL, options: .atomic)
        try Data("sistema-completo".utf8).write(to: systemURL, options: .atomic)
        try Data("microfone-completo".utf8).write(to: microphoneURL, options: .atomic)
        var manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            systemStartedAtUptime: 100,
            observedDuration: 60,
            phase: .stopped
        )
        manifest.lastObservedAt = Date()
        try manifest.writeAtomically(for: outputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let operations = TruncatedOutputRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL
        )
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in await operations.validDuration(at: url) },
            combineAudioTracks: {
                systemURL,
                microphoneURL,
                outputURL,
                systemOffset,
                microphoneOffset,
                includeSystem,
                includeMicrophone in
                try await operations.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL,
                    systemOffset: systemOffset,
                    microphoneOffset: microphoneOffset,
                    includeSystem: includeSystem,
                    includeMicrophone: includeMicrophone
                )
            }
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.recordingSegments.count == 1
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        let segment = try XCTUnwrap(recovered.recordingSegments.first)
        XCTAssertEqual(operations.combineCallCount, 1)
        XCTAssertEqual(segment.recordedDuration, 60)
        XCTAssertTrue(segment.captureWarning?.contains("estava incompleto") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: AudioCaptureRecoveryManifest.manifestURL(for: outputURL).path
            )
        )
    }

    func testRecoveryReconcilesPersistedValidM4AWhenRawSourcesAndManifestRemain() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let outputURL = try fileStore.makeSegmentURL(meetingID: meetingID, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        let microphoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-microphone.caf")
        for (url, contents) in [
            (outputURL, "final-curto"),
            (systemURL, "sistema-completo"),
            (microphoneURL, "microfone-completo")
        ] {
            try Data(contents.utf8).write(to: url, options: .atomic)
        }
        let manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            systemStartedAtUptime: 100,
            observedDuration: 60,
            phase: .stopped
        )
        try manifest.writeAtomically(for: outputURL)
        let persistedSegment = RecordingSegment(
            meetingID: meetingID,
            sequence: 1,
            fileURL: outputURL,
            recordedDuration: 1
        )
        let meeting = Meeting(
            id: meetingID,
            recordedDuration: 1,
            title: "Final persistido incompleto",
            state: .preparingAudio,
            recordingSegments: [persistedSegment]
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let operations = TruncatedOutputRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL
        )
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in await operations.validDuration(at: url) },
            combineAudioTracks: {
                systemURL,
                microphoneURL,
                outputURL,
                systemOffset,
                microphoneOffset,
                includeSystem,
                includeMicrophone in
                try await operations.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL,
                    systemOffset: systemOffset,
                    microphoneOffset: microphoneOffset,
                    includeSystem: includeSystem,
                    includeMicrophone: includeMicrophone
                )
            }
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) { operations.combineCallCount == 1 }
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meetingID })?
                .recordingSegments.first?.recordedDuration == 60
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meetingID })
        )
        let segment = try XCTUnwrap(recovered.recordingSegments.first)
        XCTAssertEqual(operations.combineCallCount, 1)
        XCTAssertEqual(recovered.recordingSegments.count, 1)
        XCTAssertEqual(segment.id, persistedSegment.id)
        XCTAssertEqual(segment.recordedDuration, 60)
        XCTAssertTrue(segment.captureWarning?.contains("estava incompleto") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: AudioCaptureRecoveryManifest.manifestURL(for: outputURL).path
            )
        )
    }

    func testRecoveryRejectsShortRebuiltOutputAndPreservesRecoveryArtifacts() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "Reconstrução curta", state: .recording)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        let microphoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-microphone.caf")
        try Data("sistema-completo".utf8).write(to: systemURL, options: .atomic)
        try Data("microfone-completo".utf8).write(to: microphoneURL, options: .atomic)
        let manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            systemStartedAtUptime: 100,
            observedDuration: 60,
            phase: .stopped
        )
        try manifest.writeAtomically(for: outputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let operations = SourceSelectionRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            initialOutputDuration: nil,
            rebuiltOutputDuration: 10,
            systemDuration: 60,
            microphoneDuration: 60
        )
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        configureRecovery(viewModel, with: operations)

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) {
            operations.combineCallCount == 1
                && viewModel.meetings.first(where: { $0.id == meeting.id })?.state == .failed
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(operations.combineCallCount, 1)
        XCTAssertEqual(recovered.state, .failed)
        XCTAssertTrue(recovered.recordingSegments.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: AudioCaptureRecoveryManifest.manifestURL(for: outputURL).path
            )
        )
    }

    func testRecoveryPreservesDecodableSystemRawTruncatedAgainstManifestDuration() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "Sistema bruto truncado", state: .recording)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        let microphoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-microphone.caf")
        try Data("sistema-1s".utf8).write(to: systemURL, options: .atomic)
        try Data("microfone-60s".utf8).write(to: microphoneURL, options: .atomic)
        let manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            systemStartedAtUptime: 100,
            observedDuration: 60,
            phase: .stopped
        )
        try manifest.writeAtomically(for: outputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let operations = SourceSelectionRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            initialOutputDuration: nil,
            rebuiltOutputDuration: 60,
            systemDuration: 1,
            microphoneDuration: 60
        )
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        configureRecovery(viewModel, with: operations)

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.recordingSegments.count == 1
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(operations.combineCallCount, 1)
        XCTAssertTrue(operations.includedSystem)
        XCTAssertTrue(operations.includedMicrophone)
        XCTAssertTrue(
            recovered.recordingSegments.first?.captureWarning?
                .contains("sistema estava truncado; o trecho decodificável foi preservado") == true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: AudioCaptureRecoveryManifest.manifestURL(for: outputURL).path
            )
        )
    }

    func testRecoveryPreservesDecodableMicrophoneRawTruncatedAgainstManifestDuration() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "Microfone bruto truncado", state: .recording)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        let microphoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-microphone.caf")
        try Data("sistema-60s".utf8).write(to: systemURL, options: .atomic)
        try Data("microfone-1s".utf8).write(to: microphoneURL, options: .atomic)
        let manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            systemStartedAtUptime: 100,
            observedDuration: 60,
            phase: .stopped
        )
        try manifest.writeAtomically(for: outputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let operations = SourceSelectionRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            initialOutputDuration: nil,
            rebuiltOutputDuration: 60,
            systemDuration: 60,
            microphoneDuration: 1
        )
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        configureRecovery(viewModel, with: operations)

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.recordingSegments.count == 1
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(operations.combineCallCount, 1)
        XCTAssertTrue(operations.includedSystem)
        XCTAssertTrue(operations.includedMicrophone)
        XCTAssertTrue(
            recovered.recordingSegments.first?.captureWarning?
                .contains("microfone estava truncado; o trecho decodificável foi preservado") == true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: AudioCaptureRecoveryManifest.manifestURL(for: outputURL).path
            )
        )
    }

    func testRecoveryHonorsFinalizedManifestThatExcludedSystemSource() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "Sistema rejeitado na finalização", state: .recording)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        let microphoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-microphone.caf")
        try Data("sistema-60s".utf8).write(to: systemURL, options: .atomic)
        try Data("microfone-60s".utf8).write(to: microphoneURL, options: .atomic)
        let expectedWarning = "A gravação foi preservada parcialmente. A fonte do sistema foi rejeitada."
        let manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            systemStartedAtUptime: 100,
            observedDuration: 60,
            stoppedAtUptime: 160,
            phase: .finalized,
            includedSystemAudio: false,
            includedMicrophoneAudio: true,
            finalizationWarning: expectedWarning
        )
        try manifest.writeAtomically(for: outputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let operations = SourceSelectionRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            initialOutputDuration: nil,
            rebuiltOutputDuration: 60,
            systemDuration: 60,
            microphoneDuration: 60
        )
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        configureRecovery(viewModel, with: operations)

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.recordingSegments.count == 1
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertFalse(operations.includedSystem)
        XCTAssertTrue(operations.includedMicrophone)
        XCTAssertEqual(recovered.recordingSegments.first?.captureWarning, expectedWarning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
    }

    func testLongMeetingTruncationToleranceDoesNotHide179MissingSeconds() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "M4A longo truncado", state: .recording)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        let microphoneURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-microphone.caf")
        for url in [outputURL, systemURL, microphoneURL] {
            try Data("fixture".utf8).write(to: url, options: .atomic)
        }
        let manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: 100,
            systemStartedAtUptime: 100,
            observedDuration: 3_600,
            stoppedAtUptime: 3_700,
            phase: .stopped
        )
        try manifest.writeAtomically(for: outputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let operations = SourceSelectionRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            initialOutputDuration: 3_421,
            rebuiltOutputDuration: 3_600,
            systemDuration: 3_600,
            microphoneDuration: 3_600
        )
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        configureRecovery(viewModel, with: operations)

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.recordingSegments.count == 1
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(operations.combineCallCount, 1)
        XCTAssertEqual(recovered.recordingSegments.first?.recordedDuration, 3_600)
        XCTAssertTrue(recovered.recordingSegments.first?.captureWarning?.contains("estava incompleto") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
    }

    func testRecoveryReplacesPersistedSequenceWhoseM4AIsMissingWhenRawExists() async throws {
        try await assertRecoveryReplacesInvalidPersistedSegment(makeCorruptFile: false)
    }

    func testRecoveryReplacesPersistedSequenceWhoseM4AIsCorruptWhenRawExists() async throws {
        try await assertRecoveryReplacesInvalidPersistedSegment(makeCorruptFile: true)
    }

    func testRecoveryRestoresPartialSourceWarningFromFinalizationManifest() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "Export parcial interrompido", state: .preparingAudio)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        try Data("final-válido".utf8).write(to: outputURL, options: .atomic)
        try Data("sistema-válido".utf8).write(to: systemURL, options: .atomic)
        let expectedWarning = "A gravação foi preservada parcialmente. O microfone foi interrompido."
        let manifest = AudioCaptureRecoveryManifest(
            outputFileName: outputURL.lastPathComponent,
            preparationStartedAtUptime: 100,
            microphoneStartedAtUptime: nil,
            systemStartedAtUptime: 100,
            observedDuration: 10,
            stoppedAtUptime: 110,
            phase: .finalized,
            includedSystemAudio: true,
            includedMicrophoneAudio: false,
            finalizationWarning: expectedWarning
        )
        try manifest.writeAtomically(for: outputURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let operations = ExistingFinalOutputRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL
        )
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in await operations.validDuration(at: url) },
            combineAudioTracks: { _, _, _, _, _, _, _ in
                XCTFail("Um arquivo final completo não deve ser exportado novamente.")
                throw RecordingError.fileWriteFailed("Exportação inesperada.")
            }
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.recordingSegments.count == 1
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(recovered.recordingSegments.first?.captureWarning, expectedWarning)
        XCTAssertEqual(recovered.captureWarnings, [expectedWarning])
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testRecoveryDoesNotMutateAnotherMeetingWhenInterruptedMeetingIsDeletedDuringCombine() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let interrupted = Meeting(title: "Excluir durante recuperação", state: .failed)
        let survivor = Meeting(title: "Reunião preservada", state: .completed)
        let outputURL = try fileStore.makeSegmentURL(meetingID: interrupted.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        try writeShortCAF(to: systemURL)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recoveryOperations = SuspendedCombineRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL
        )
        let viewModel = makeViewModel(
            meetings: [interrupted, survivor],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService()
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in
                await recoveryOperations.validDuration(at: url)
            },
            combineAudioTracks: {
                systemURL, microphoneURL, outputURL, _, _, _, _ in
                try await recoveryOperations.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL
                )
            }
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) { recoveryOperations.isWaiting }
        XCTAssertTrue(recoveryOperations.isWaiting)

        let meetingToDelete = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == interrupted.id })
        )
        XCTAssertTrue(viewModel.canDeleteMeeting(meetingToDelete))
        viewModel.deleteMeeting(meetingToDelete)
        XCTAssertFalse(viewModel.meetings.contains(where: { $0.id == interrupted.id }))

        recoveryOperations.resumeCombine()
        await waitUntil(timeout: 2) { !recoveryOperations.isWaiting }

        XCTAssertFalse(viewModel.meetings.contains(where: { $0.id == interrupted.id }))
        let unchangedSurvivor = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == survivor.id })
        )
        XCTAssertEqual(unchangedSurvivor.state, .completed)
        XCTAssertTrue(unchangedSurvivor.recordingSegments.isEmpty)
    }

    func testRepeatedSetupRetryRemainsSingleFlightWhileRecoveryCombineIsSuspended() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "Retry durante recuperação", state: .recording)
        let outputURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        try Data("raw-system".utf8).write(to: systemURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recoveryOperations = SetupRetryRecoveryOperations(
            outputURL: outputURL,
            systemURL: systemURL
        )
        let resourcePreparer = RecoverySuspendedResourcePreparer()
        let viewModel = makeViewModel(
            meetings: [meeting],
            fileStore: fileStore,
            captureService: RecoveryNoopAudioCaptureService(),
            resourcePreparer: resourcePreparer
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in
                await recoveryOperations.validDuration(at: url)
            },
            combineAudioTracks: {
                systemURL, microphoneURL, outputURL, _, _, _, _ in
                try await recoveryOperations.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL
                )
            }
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) { recoveryOperations.isWaiting }
        XCTAssertEqual(recoveryOperations.combineCallCount, 1)

        viewModel.retryApplicationSetup()
        viewModel.retryApplicationSetup()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recoveryOperations.combineCallCount, 1)
        XCTAssertEqual(resourcePreparer.prepareCount, 0)

        recoveryOperations.resumeCombine()
        await waitUntil(timeout: 2) { resourcePreparer.isWaiting }
        XCTAssertEqual(recoveryOperations.combineCallCount, 1)
        XCTAssertEqual(resourcePreparer.prepareCount, 1)

        // The cancelled generation must not clear the newest task handle.
        viewModel.startApplicationServices()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(resourcePreparer.prepareCount, 1)

        resourcePreparer.resumePreparation()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.state == .completed
        }
        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == meeting.id })?.state,
            .completed
        )
        XCTAssertEqual(recoveryOperations.combineCallCount, 1)
        XCTAssertEqual(resourcePreparer.prepareCount, 1)
    }

    func testStartingRecordingKeepsImmutableMeetingSelectedAndBlocksNavigationAndDeletion() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let existing = Meeting(title: "Reunião existente", state: .completed)
        let captureService = RecoverySuspendedStartAudioCaptureService()
        let viewModel = makeViewModel(
            meetings: [existing],
            fileStore: fileStore,
            captureService: captureService
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let startTask = Task { await viewModel.beginRecording() }
        await waitUntil(timeout: 2) {
            viewModel.isStartingRecording && captureService.isWaiting
        }

        let newMeetingID = try XCTUnwrap(viewModel.selectedMeetingID)
        let preparingMeeting = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == newMeetingID })
        )
        XCTAssertNotEqual(newMeetingID, existing.id)
        XCTAssertEqual(preparingMeeting.state, .idle)
        XCTAssertFalse(viewModel.canDeleteMeeting(preparingMeeting))

        viewModel.showSettings()
        viewModel.showRecordings()
        viewModel.selectMeeting(existing)
        viewModel.deleteMeeting(preparingMeeting)

        XCTAssertEqual(viewModel.screen, .empty)
        XCTAssertEqual(viewModel.selectedMeetingID, newMeetingID)
        XCTAssertTrue(viewModel.meetings.contains(where: { $0.id == newMeetingID }))
        XCTAssertTrue(viewModel.meetings.contains(where: { $0.id == existing.id }))

        captureService.resumeStart()
        await startTask.value

        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertEqual(viewModel.selectedMeetingID, newMeetingID)
        XCTAssertEqual(viewModel.meetings.filter { $0.state == .recording }.map(\.id), [newMeetingID])
        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == existing.id })?.state,
            .completed
        )

        await viewModel.finishActiveRecording()
        XCTAssertEqual(captureService.stopCount, 1)
        XCTAssertEqual(viewModel.screen, .empty)
        XCTAssertNil(viewModel.selectedMeetingID)
    }

    func testViewModelRecoversAudioMarkedFailedByAnOlderBuild() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meeting = Meeting(title: "Falha antiga recuperável", state: .failed)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let finalURL = try fileStore.makeSegmentURL(meetingID: meeting.id, sequence: 1)
        let systemURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        try writeShortCAF(to: systemURL)

        let store = MockMeetingStore(meetings: [meeting])
        let viewModel = MeetingViewModel(
            store: store,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: RecoveryNoopAudioCaptureService(),
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: RecoveryAudioValidatingWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: RecoverySummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: RecoveryCalendarService(),
            reminderScheduler: RecoveryReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: RecoveryResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 8) {
            viewModel.meetings.first(where: { $0.id == meeting.id })?.state == .completed
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meeting.id })
        )
        XCTAssertEqual(recovered.recordingSegments.count, 1)
        XCTAssertGreaterThan(recovered.recordedDuration, 0)
        XCTAssertFalse(recovered.transcript.isEmpty)
    }

    func testViewModelRecoversNextRawSegmentAfterBackgroundFinalizationWasInterrupted() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let firstURL = rootURL
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("segment-001.caf")
        let meeting = Meeting(
            id: meetingID,
            title: "Finalização interrompida",
            state: .preparingAudio,
            recordingSegments: [
                RecordingSegment(
                    meetingID: meetingID,
                    sequence: 1,
                    fileURL: firstURL,
                    recordedDuration: 0.25
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: firstURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeShortCAF(to: firstURL)
        let secondOutputURL = try fileStore.makeSegmentURL(meetingID: meetingID, sequence: 2)
        let secondSystemURL = secondOutputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-002-system.caf")
        try writeShortCAF(to: secondSystemURL)

        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: RecoveryNoopAudioCaptureService(),
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: RecoveryAudioValidatingWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: RecoverySummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: RecoveryCalendarService(),
            reminderScheduler: RecoveryReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: RecoveryResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 8) {
            viewModel.meetings.first(where: { $0.id == meetingID })?.state == .completed
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meetingID })
        )
        XCTAssertEqual(recovered.recordingSegments.map(\.sequence), [1, 2])
        XCTAssertTrue(recovered.recordingSegments.allSatisfy { $0.recordedDuration > 0 })
        XCTAssertFalse(recovered.transcript.isEmpty)
    }

    func testSelectingMeetingDuringRecoveryWaitsForAllSegmentsAndTranscribesEachExactlyOnce() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let meetingID = UUID()
        let firstOutputURL = try fileStore.makeSegmentURL(meetingID: meetingID, sequence: 1)
        let secondOutputURL = try fileStore.makeSegmentURL(meetingID: meetingID, sequence: 2)
        let secondSystemURL = secondOutputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-002-system.caf")
        let firstSegment = RecordingSegment(
            meetingID: meetingID,
            sequence: 1,
            fileURL: firstOutputURL,
            recordedDuration: 1
        )
        let meeting = Meeting(
            id: meetingID,
            recordedDuration: 1,
            title: "Recuperação selecionada",
            state: .preparingAudio,
            recordingSegments: [firstSegment]
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try Data("segmento-1".utf8).write(to: firstOutputURL, options: .atomic)
        try Data("sistema-segmento-2".utf8).write(to: secondSystemURL, options: .atomic)

        let recoveryOperations = SelectedDuringRecoveryOperations(
            firstOutputURL: firstOutputURL,
            secondOutputURL: secondOutputURL,
            secondSystemURL: secondSystemURL
        )
        let transcriptionRecorder = RecoveryTranscriptionRecorder()
        let viewModel = MeetingViewModel(
            store: MockMeetingStore(meetings: [meeting]),
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: RecoveryNoopAudioCaptureService(),
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: RecoveryCountingWhisperService(recorder: transcriptionRecorder),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: RecoverySummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: RecoveryCalendarService(),
            reminderScheduler: RecoveryReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: RecoveryResourcePreparer()
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in
                await recoveryOperations.validDuration(at: url)
            },
            combineAudioTracks: {
                systemURL, microphoneURL, outputURL, _, _, includeSystem, includeMicrophone in
                try await recoveryOperations.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL,
                    includeSystem: includeSystem,
                    includeMicrophone: includeMicrophone
                )
            }
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 2) { recoveryOperations.isWaiting }
        XCTAssertTrue(recoveryOperations.isWaiting)

        let meetingDuringRecovery = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meetingID })
        )
        viewModel.selectMeeting(meetingDuringRecovery)
        XCTAssertEqual(viewModel.screen, .processing)
        try await Task.sleep(for: .milliseconds(100))
        let sequencesBeforeRecoveryCompleted = await transcriptionRecorder.recordedSequences()
        XCTAssertTrue(sequencesBeforeRecoveryCompleted.isEmpty)

        recoveryOperations.resumeCombine()
        await waitUntil(timeout: 2) {
            viewModel.meetings.first(where: { $0.id == meetingID })?.state == .completed
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meetingID })
        )
        let transcribedSequences = await transcriptionRecorder.recordedSequences()
        XCTAssertEqual(recovered.state, .completed)
        XCTAssertEqual(recovered.recordingSegments.map(\.sequence), [1, 2])
        XCTAssertEqual(recovered.transcript, "Segmento 1\n\nSegmento 2")
        XCTAssertEqual(transcribedSequences, [1, 2])
    }

    private func writeShortCAF(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frameCount: AVAudioFrameCount = 12_000
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = 0.2 * sin(2 * .pi * 440 * Float(frame) / 48_000)
        }
        try file.write(from: buffer)
    }

    private func configureRecovery(
        _ viewModel: MeetingViewModel,
        with operations: SourceSelectionRecoveryOperations
    ) {
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in await operations.validDuration(at: url) },
            combineAudioTracks: {
                systemURL,
                microphoneURL,
                outputURL,
                systemOffset,
                microphoneOffset,
                includeSystem,
                includeMicrophone in
                try await operations.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL,
                    systemOffset: systemOffset,
                    microphoneOffset: microphoneOffset,
                    includeSystem: includeSystem,
                    includeMicrophone: includeMicrophone
                )
            }
        )
    }

    private func assertRecoveryReplacesInvalidPersistedSegment(
        makeCorruptFile: Bool
    ) async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = rootURL.appendingPathComponent("Persistence/QAPia.store")
        let fileStore = LocalMeetingFileStore(
            rootURL: rootURL.appendingPathComponent("Meetings", isDirectory: true)
        )
        let meetingID = UUID()
        let outputURL = try fileStore.makeSegmentURL(meetingID: meetingID, sequence: 1)
        let systemURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("segment-001-system.caf")
        try writeShortCAF(to: systemURL)
        if makeCorruptFile {
            try Data("m4a-corrompido".utf8).write(to: outputURL, options: .atomic)
        }
        let persistedSegment = RecordingSegment(
            meetingID: meetingID,
            sequence: 1,
            fileURL: outputURL,
            recordedDuration: 120
        )
        let meeting = Meeting(
            id: meetingID,
            recordedDuration: 120,
            title: makeCorruptFile ? "Segmento corrompido" : "Segmento ausente",
            state: .recording,
            recordingSegments: [persistedSegment]
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        do {
            let store = try SwiftDataMeetingStore(storeURL: storeURL)
            try store.save(meeting)
        }
        let reopenedStore = try SwiftDataMeetingStore(storeURL: storeURL)
        let viewModel = MeetingViewModel(
            store: reopenedStore,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: RecoveryNoopAudioCaptureService(),
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: RecoveryAudioValidatingWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: RecoverySummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: RecoveryCalendarService(),
            reminderScheduler: RecoveryReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: RecoveryResourcePreparer()
        )

        viewModel.startApplicationServices()
        await waitUntil(timeout: 8) {
            viewModel.meetings.first(where: { $0.id == meetingID })?.state == .completed
        }

        let recovered = try XCTUnwrap(
            viewModel.meetings.first(where: { $0.id == meetingID })
        )
        let replacement = try XCTUnwrap(recovered.recordingSegments.first)
        XCTAssertEqual(recovered.state, .completed)
        XCTAssertEqual(recovered.recordingSegments.count, 1)
        XCTAssertEqual(replacement.id, persistedSegment.id)
        XCTAssertEqual(replacement.sequence, 1)
        XCTAssertNotEqual(replacement.recordedDuration, 120)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.fileURL.path))
        XCTAssertFalse(recovered.transcript.isEmpty)

        let reloaded = try XCTUnwrap(
            reopenedStore.loadMeetings().first(where: { $0.id == meetingID })
        )
        XCTAssertEqual(reloaded.recordingSegments.count, 1)
        XCTAssertEqual(reloaded.recordingSegments.first?.id, persistedSegment.id)
        XCTAssertEqual(reloaded.recordingSegments.first?.sequence, 1)
        XCTAssertFalse(reloaded.transcript.isEmpty)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeViewModel(
        meetings: [Meeting],
        fileStore: LocalMeetingFileStore,
        captureService: AudioCaptureService,
        resourcePreparer: LocalResourcePreparing = RecoveryResourcePreparer()
    ) -> MeetingViewModel {
        MeetingViewModel(
            store: MockMeetingStore(meetings: meetings),
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: captureService,
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: RecoveryStaticWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: RecoverySummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: RecoveryCalendarService(),
            reminderScheduler: RecoveryReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: resourcePreparer
        )
    }
}

private struct RecoveryStaticWhisperService: WhisperService {
    func transcribe(segment: RecordingSegment) async throws -> String {
        "Transcrição de teste."
    }
}

private struct RecoverySequencedWhisperService: WhisperService {
    func transcribe(segment: RecordingSegment) async throws -> String {
        "Segmento \(segment.sequence)"
    }
}

private actor RecoveryTranscriptionRecorder {
    private var sequences: [Int] = []

    func record(_ sequence: Int) -> String {
        sequences.append(sequence)
        return "Segmento \(sequence)"
    }

    func recordedSequences() -> [Int] {
        sequences
    }
}

private struct RecoveryCountingWhisperService: WhisperService {
    let recorder: RecoveryTranscriptionRecorder

    func transcribe(segment: RecordingSegment) async throws -> String {
        await recorder.record(segment.sequence)
    }
}

@MainActor
private final class SuspendedValidationRecoveryOperations {
    let suspendedURL: URL
    let duration: TimeInterval
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSuspend = false
    private(set) var isWaiting = false

    init(suspendedURL: URL, duration: TimeInterval) {
        self.suspendedURL = suspendedURL
        self.duration = duration
    }

    func validDuration(at url: URL) async -> TimeInterval? {
        guard url == suspendedURL else { return nil }
        if !didSuspend {
            didSuspend = true
            isWaiting = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            isWaiting = false
        }
        return duration
    }

    func combine(systemURL: URL, microphoneURL: URL, outputURL: URL) async throws -> URL {
        XCTFail("A combinação não deveria ser necessária quando o arquivo final é válido.")
        throw RecordingError.fileWriteFailed("Combinação inesperada.")
    }

    func resumeValidation() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SuspendedCombineRecoveryOperations {
    let outputURL: URL
    let systemURL: URL
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    init(outputURL: URL, systemURL: URL) {
        self.outputURL = outputURL
        self.systemURL = systemURL
    }

    func validDuration(at url: URL) async -> TimeInterval? {
        url == systemURL ? 0.25 : nil
    }

    func combine(systemURL: URL, microphoneURL: URL, outputURL: URL) async throws -> URL {
        XCTAssertEqual(systemURL, self.systemURL)
        XCTAssertEqual(outputURL, self.outputURL)
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
        return outputURL
    }

    func resumeCombine() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SelectedDuringRecoveryOperations {
    let firstOutputURL: URL
    let secondOutputURL: URL
    let secondSystemURL: URL
    private var continuation: CheckedContinuation<Void, Never>?
    private var secondOutputIsReady = false
    private(set) var isWaiting = false

    init(firstOutputURL: URL, secondOutputURL: URL, secondSystemURL: URL) {
        self.firstOutputURL = firstOutputURL
        self.secondOutputURL = secondOutputURL
        self.secondSystemURL = secondSystemURL
    }

    func validDuration(at url: URL) async -> TimeInterval? {
        if url == firstOutputURL || url == secondSystemURL { return 1 }
        if url == secondOutputURL { return secondOutputIsReady ? 1 : nil }
        return nil
    }

    func combine(
        systemURL: URL,
        microphoneURL: URL,
        outputURL: URL,
        includeSystem: Bool,
        includeMicrophone: Bool
    ) async throws -> URL {
        XCTAssertEqual(systemURL, secondSystemURL)
        XCTAssertEqual(outputURL, secondOutputURL)
        XCTAssertTrue(includeSystem)
        XCTAssertFalse(includeMicrophone)
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        try Data("segmento-2-recuperado".utf8).write(to: outputURL, options: .atomic)
        secondOutputIsReady = true
        isWaiting = false
        return outputURL
    }

    func resumeCombine() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RecoveryOffsetCapturingOperations {
    let outputURL: URL
    let systemURL: URL
    let microphoneURL: URL
    private(set) var combineCallCount = 0
    private(set) var systemOffset: TimeInterval = -1
    private(set) var microphoneOffset: TimeInterval = -1
    private(set) var includedSystem = false
    private(set) var includedMicrophone = false
    private var outputIsReady = false

    init(outputURL: URL, systemURL: URL, microphoneURL: URL) {
        self.outputURL = outputURL
        self.systemURL = systemURL
        self.microphoneURL = microphoneURL
    }

    func validDuration(at url: URL) async -> TimeInterval? {
        if url == outputURL { return outputIsReady ? 2.25 : nil }
        if url == systemURL { return 0.25 }
        if url == microphoneURL { return 2.25 }
        return nil
    }

    func combine(
        systemURL: URL,
        microphoneURL: URL,
        outputURL: URL,
        systemOffset: TimeInterval,
        microphoneOffset: TimeInterval,
        includeSystem: Bool,
        includeMicrophone: Bool
    ) async throws -> URL {
        XCTAssertEqual(systemURL, self.systemURL)
        XCTAssertEqual(microphoneURL, self.microphoneURL)
        XCTAssertEqual(outputURL, self.outputURL)
        combineCallCount += 1
        self.systemOffset = systemOffset
        self.microphoneOffset = microphoneOffset
        includedSystem = includeSystem
        includedMicrophone = includeMicrophone
        try Data(contentsOf: microphoneURL).write(to: outputURL, options: .atomic)
        outputIsReady = true
        return outputURL
    }
}

@MainActor
private final class TruncatedOutputRecoveryOperations {
    let outputURL: URL
    let systemURL: URL
    let microphoneURL: URL
    private var outputWasRebuilt = false
    private(set) var combineCallCount = 0

    init(outputURL: URL, systemURL: URL, microphoneURL: URL) {
        self.outputURL = outputURL
        self.systemURL = systemURL
        self.microphoneURL = microphoneURL
    }

    func validDuration(at url: URL) async -> TimeInterval? {
        if url == outputURL { return outputWasRebuilt ? 60 : 1 }
        if url == systemURL || url == microphoneURL { return 60 }
        return nil
    }

    func combine(
        systemURL: URL,
        microphoneURL: URL,
        outputURL: URL,
        systemOffset: TimeInterval,
        microphoneOffset: TimeInterval,
        includeSystem: Bool,
        includeMicrophone: Bool
    ) async throws -> URL {
        XCTAssertEqual(systemURL, self.systemURL)
        XCTAssertEqual(microphoneURL, self.microphoneURL)
        XCTAssertEqual(outputURL, self.outputURL)
        XCTAssertEqual(systemOffset, 0)
        XCTAssertEqual(microphoneOffset, 0)
        XCTAssertTrue(includeSystem)
        XCTAssertTrue(includeMicrophone)
        combineCallCount += 1
        outputWasRebuilt = true
        try Data("final-reconstruído".utf8).write(to: outputURL, options: .atomic)
        return outputURL
    }
}

@MainActor
private final class ExistingFinalOutputRecoveryOperations {
    let outputURL: URL
    let systemURL: URL

    init(outputURL: URL, systemURL: URL) {
        self.outputURL = outputURL
        self.systemURL = systemURL
    }

    func validDuration(at url: URL) async -> TimeInterval? {
        if url == outputURL || url == systemURL { return 10 }
        return nil
    }
}

@MainActor
private final class SourceSelectionRecoveryOperations {
    let outputURL: URL
    let systemURL: URL
    let microphoneURL: URL
    let initialOutputDuration: TimeInterval?
    let rebuiltOutputDuration: TimeInterval
    let systemDuration: TimeInterval?
    let microphoneDuration: TimeInterval?
    private var outputWasRebuilt = false
    private(set) var combineCallCount = 0
    private(set) var includedSystem = false
    private(set) var includedMicrophone = false

    init(
        outputURL: URL,
        systemURL: URL,
        microphoneURL: URL,
        initialOutputDuration: TimeInterval?,
        rebuiltOutputDuration: TimeInterval,
        systemDuration: TimeInterval?,
        microphoneDuration: TimeInterval?
    ) {
        self.outputURL = outputURL
        self.systemURL = systemURL
        self.microphoneURL = microphoneURL
        self.initialOutputDuration = initialOutputDuration
        self.rebuiltOutputDuration = rebuiltOutputDuration
        self.systemDuration = systemDuration
        self.microphoneDuration = microphoneDuration
    }

    func validDuration(at url: URL) async -> TimeInterval? {
        if url == outputURL {
            return outputWasRebuilt ? rebuiltOutputDuration : initialOutputDuration
        }
        if url == systemURL { return systemDuration }
        if url == microphoneURL { return microphoneDuration }
        return nil
    }

    func combine(
        systemURL: URL,
        microphoneURL: URL,
        outputURL: URL,
        systemOffset: TimeInterval,
        microphoneOffset: TimeInterval,
        includeSystem: Bool,
        includeMicrophone: Bool
    ) async throws -> URL {
        XCTAssertEqual(systemURL, self.systemURL)
        XCTAssertEqual(microphoneURL, self.microphoneURL)
        XCTAssertEqual(outputURL, self.outputURL)
        combineCallCount += 1
        includedSystem = includeSystem
        includedMicrophone = includeMicrophone
        outputWasRebuilt = true
        try Data("final-reconstruído".utf8).write(to: outputURL, options: .atomic)
        return outputURL
    }
}

@MainActor
private final class SetupRetryRecoveryOperations {
    let outputURL: URL
    let systemURL: URL
    private var continuation: CheckedContinuation<Void, Never>?
    private var outputIsReady = false
    private(set) var isWaiting = false
    private(set) var combineCallCount = 0

    init(outputURL: URL, systemURL: URL) {
        self.outputURL = outputURL
        self.systemURL = systemURL
    }

    func validDuration(at url: URL) async -> TimeInterval? {
        if url == outputURL { return outputIsReady ? 1 : nil }
        if url == systemURL { return 1 }
        return nil
    }

    func combine(systemURL: URL, microphoneURL: URL, outputURL: URL) async throws -> URL {
        XCTAssertEqual(systemURL, self.systemURL)
        XCTAssertEqual(outputURL, self.outputURL)
        combineCallCount += 1
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        try Data("final-recuperado".utf8).write(to: outputURL, options: .atomic)
        outputIsReady = true
        isWaiting = false
        return outputURL
    }

    func resumeCombine() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RecoverySuspendedResourcePreparer: LocalResourcePreparing, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var prepareCount = 0
    private(set) var isWaiting = false

    func prepare() async throws {
        prepareCount += 1
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
    }

    func resumePreparation() {
        continuation?.resume()
        continuation = nil
    }
}

private struct RecoveryAudioValidatingWhisperService: WhisperService {
    func transcribe(segment: RecordingSegment) async throws -> String {
        let asset = AVURLAsset(url: segment.fileURL)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
              CMTimeGetSeconds(try await asset.load(.duration)) > 0 else {
            throw WhisperModelError.audioDecodingFailed("O áudio recuperado é inválido.")
        }
        return "Áudio recuperado e validado."
    }
}

private struct RecoverySummaryProvider: SummaryProvider {
    func generateSummary(
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String {
        "# Resumo\n\nGravação recuperada."
    }
}

private struct RecoveryResourcePreparer: LocalResourcePreparing {
    func prepare() async throws {}
}

@MainActor
private final class RecoveryNoopAudioCaptureService: AudioCaptureService {
    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        throw RecordingError.captureFailed("Captura não deveria iniciar durante a recuperação.")
    }

    func stopSegment() async throws -> CapturedAudio {
        throw RecordingError.noActiveRecording
    }
}

@MainActor
private final class RecoveryImmediateAudioCaptureService: AudioCaptureService {
    private var activeURL: URL?
    private(set) var stopCount = 0

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        guard activeURL == nil else { throw RecordingError.alreadyRecording }
        activeURL = fileURL
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let activeURL else { throw RecordingError.noActiveRecording }
        self.activeURL = nil
        stopCount += 1
        return CapturedAudio(fileURL: activeURL, duration: 1)
    }
}

@MainActor
private final class RecoverySuspendedStartAudioCaptureService: AudioCaptureService {
    private var continuation: CheckedContinuation<Void, Never>?
    private var activeURL: URL?
    private(set) var isWaiting = false
    private(set) var stopCount = 0

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        guard activeURL == nil else { throw RecordingError.alreadyRecording }
        activeURL = fileURL
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
    }

    func resumeStart() {
        continuation?.resume()
        continuation = nil
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let activeURL else { throw RecordingError.noActiveRecording }
        self.activeURL = nil
        stopCount += 1
        return CapturedAudio(fileURL: activeURL, duration: 1)
    }
}

@MainActor
private final class RecoveryCalendarService: GoogleCalendarServing {
    var isConfigured: Bool { false }

    func restoreAccount() async -> GoogleCalendarAccount? { nil }

    func connect() async throws -> GoogleCalendarAccount {
        throw GoogleCalendarError.missingConfiguration
    }

    func disconnect() async {}

    func upcomingEvents(from: Date, through: Date) async throws -> [CalendarEvent] { [] }
}

@MainActor
private final class RecoveryReminderScheduler: CalendarReminderScheduling {
    func scheduleReminders(for events: [CalendarEvent]) async {}
}
