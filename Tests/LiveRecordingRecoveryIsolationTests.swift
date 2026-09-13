import Foundation
import XCTest
@testable import QapiaCore

@MainActor
final class LiveRecordingRecoveryIsolationTests: XCTestCase {
    func testSetupRetryNeverRecoversTheLiveRecordingCreatedAfterColdLaunch() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let store = MockMeetingStore(meetings: [])
        let captureService = LiveRawWriterCaptureService()
        let resourcePreparer = FailFirstResourcePreparer()
        let recoveryProbe = LiveRecoveryProbe()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let viewModel = MeetingViewModel(
            store: store,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(
                captureService: captureService,
                fileStore: fileStore
            ),
            transcriptionService: TranscriptionService(
                whisperService: IsolationWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: IsolationSummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: IsolationCalendarService(),
            reminderScheduler: IsolationReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: resourcePreparer
        )
        viewModel.configureInterruptedRecordingRecoveryForTesting(
            validAudioDuration: { url in
                recoveryProbe.validate(url)
            },
            combineAudioTracks: {
                systemURL, microphoneURL, outputURL, _, _, _, _ in
                try recoveryProbe.combine(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    outputURL: outputURL
                )
            }
        )

        // The first launch has no interrupted rows and fails only while
        // preparing the transcription resource.
        viewModel.startApplicationServices()
        await waitUntil { resourcePreparer.prepareCount == 1 }
        try await Task.sleep(for: .milliseconds(20))

        await viewModel.beginRecording()
        let liveMeetingID = try XCTUnwrap(viewModel.selectedMeetingID)
        let rawURL = try XCTUnwrap(captureService.rawURL)
        let rawBytesBeforeRetry = try Data(contentsOf: rawURL)
        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertTrue(captureService.hasOpenWriter)

        // This is the retry exposed by RootView after setup failure. It must
        // prepare only the missing resource; recovery belongs exclusively to
        // the immutable cold-launch allowlist.
        viewModel.retryApplicationSetup()
        await waitUntil { resourcePreparer.prepareCount == 2 }
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(recoveryProbe.validationCount, 0)
        XCTAssertEqual(recoveryProbe.combineCount, 0)
        XCTAssertEqual(try Data(contentsOf: rawURL), rawBytesBeforeRetry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
        XCTAssertTrue(captureService.hasOpenWriter)
        XCTAssertEqual(viewModel.selectedMeetingID, liveMeetingID)
        XCTAssertEqual(viewModel.screen, .recording)
        XCTAssertEqual(
            viewModel.meetings.first(where: { $0.id == liveMeetingID })?.state,
            .recording
        )
        XCTAssertTrue(
            viewModel.meetings.first(where: { $0.id == liveMeetingID })?
                .recordingSegments.isEmpty == true
        )

        await viewModel.finishActiveRecording()
        XCTAssertEqual(captureService.stopCount, 1)
        XCTAssertFalse(captureService.hasOpenWriter)
        XCTAssertEqual(recoveryProbe.validationCount, 0)
        XCTAssertEqual(recoveryProbe.combineCount, 0)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class LiveRawWriterCaptureService: AudioCaptureService {
    private var activeOutputURL: URL?
    private var rawHandle: FileHandle?
    private(set) var rawURL: URL?
    private(set) var stopCount = 0

    var hasOpenWriter: Bool { rawHandle != nil }

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        guard activeOutputURL == nil else { throw RecordingError.alreadyRecording }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let rawURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-system.caf")
        let seed = Data("live-writer-owned-by-capture".utf8)
        try seed.write(to: rawURL, options: .atomic)
        let rawHandle = try FileHandle(forWritingTo: rawURL)
        try rawHandle.seekToEnd()

        activeOutputURL = fileURL
        self.rawURL = rawURL
        self.rawHandle = rawHandle
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let activeOutputURL else { throw RecordingError.noActiveRecording }
        try rawHandle?.close()
        rawHandle = nil
        self.activeOutputURL = nil
        stopCount += 1
        try Data("capture-finalized-normally".utf8).write(
            to: activeOutputURL,
            options: .atomic
        )
        return CapturedAudio(fileURL: activeOutputURL, duration: 1)
    }
}

@MainActor
private final class LiveRecoveryProbe {
    private(set) var validationCount = 0
    private(set) var combineCount = 0

    func validate(_ url: URL) -> TimeInterval? {
        validationCount += 1
        return FileManager.default.fileExists(atPath: url.path) ? 1 : nil
    }

    func combine(systemURL: URL, microphoneURL: URL, outputURL: URL) throws -> URL {
        combineCount += 1
        let sourceURL = FileManager.default.fileExists(atPath: systemURL.path)
            ? systemURL
            : microphoneURL
        try Data(contentsOf: sourceURL).write(to: outputURL, options: .atomic)
        return outputURL
    }
}

@MainActor
private final class FailFirstResourcePreparer: LocalResourcePreparing, @unchecked Sendable {
    private(set) var prepareCount = 0

    func prepare() async throws {
        prepareCount += 1
        if prepareCount == 1 {
            throw PreparationFailure.expected
        }
    }

    private enum PreparationFailure: Error {
        case expected
    }
}

private struct IsolationWhisperService: WhisperService {
    func transcribe(segment: RecordingSegment) async throws -> String {
        "Transcrição de isolamento."
    }
}

private struct IsolationSummaryProvider: SummaryProvider {
    func generateSummary(transcript: String, template: SummaryTemplate) async throws -> String {
        "# Resumo\n\nIsolamento validado."
    }
}

@MainActor
private final class IsolationCalendarService: GoogleCalendarServing {
    var isConfigured: Bool { false }

    func restoreAccount() async -> GoogleCalendarAccount? { nil }

    func connect() async throws -> GoogleCalendarAccount {
        throw GoogleCalendarError.missingConfiguration
    }

    func disconnect() async {}

    func upcomingEvents(from: Date, through: Date) async throws -> [CalendarEvent] { [] }
}

@MainActor
private final class IsolationReminderScheduler: CalendarReminderScheduling {
    func scheduleReminders(for events: [CalendarEvent]) async {}
}
