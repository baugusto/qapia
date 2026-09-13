import Foundation
import XCTest
@testable import QapiaCore

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    func testTerminationDuringRecordingStopsAndPersistsExactlyOnceAcrossConcurrentRequests() async throws {
        let fixture = makeFixture(suspendStops: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        await fixture.viewModel.beginRecording()
        let meetingID = try XCTUnwrap(fixture.viewModel.selectedMeetingID)

        let firstTermination = Task { await fixture.viewModel.prepareForTermination() }
        await waitUntil { fixture.capture.isStopWaiting }
        let secondTermination = Task { await fixture.viewModel.prepareForTermination() }

        XCTAssertEqual(fixture.capture.stopCount, 1)
        XCTAssertFalse(firstTermination.isCancelled)
        fixture.capture.resumeStop()

        let firstResult = await firstTermination.value
        let secondResult = await secondTermination.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(fixture.capture.stopCount, 1)

        let persisted = try XCTUnwrap(
            fixture.store.loadMeetings().first(where: { $0.id == meetingID })
        )
        XCTAssertEqual(persisted.state, .preparingAudio)
        XCTAssertEqual(persisted.recordingSegments.count, 1)
        XCTAssertEqual(
            fixture.store.savedSnapshots.filter {
                $0.id == meetingID && $0.recordingSegments.count == 1
            }.count,
            1
        )
    }

    func testTerminationFromPausedStateDoesNotStopSameSegmentTwice() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        await fixture.viewModel.beginRecording()
        let meetingID = try XCTUnwrap(fixture.viewModel.selectedMeetingID)
        await fixture.viewModel.pauseActiveRecording()
        XCTAssertEqual(fixture.capture.stopCount, 1)
        XCTAssertEqual(fixture.viewModel.screen, .paused)

        let terminationResult = await fixture.viewModel.prepareForTermination()
        XCTAssertTrue(terminationResult)

        XCTAssertEqual(fixture.capture.stopCount, 1)
        let persisted = try XCTUnwrap(
            fixture.store.loadMeetings().first(where: { $0.id == meetingID })
        )
        XCTAssertEqual(persisted.state, .preparingAudio)
        XCTAssertEqual(persisted.recordingSegments.map(\.sequence), [1])
    }

    func testTerminationWaitsForAnExistingAudioFinalizationWithoutDuplicatingIt() async throws {
        let fixture = makeFixture(suspendStops: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        await fixture.viewModel.beginRecording()
        let meetingID = try XCTUnwrap(fixture.viewModel.selectedMeetingID)
        let userFinish = Task { await fixture.viewModel.finishActiveRecording() }
        await waitUntil { fixture.capture.isStopWaiting }

        var terminationDidReturn = false
        let termination = Task {
            let result = await fixture.viewModel.prepareForTermination()
            terminationDidReturn = true
            return result
        }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(terminationDidReturn)
        XCTAssertEqual(fixture.capture.stopCount, 1)
        fixture.capture.resumeStop()

        await userFinish.value
        let terminationResult = await termination.value
        XCTAssertTrue(terminationResult)
        XCTAssertEqual(fixture.capture.stopCount, 1)
        let persisted = try XCTUnwrap(
            fixture.store.loadMeetings().first(where: { $0.id == meetingID })
        )
        XCTAssertEqual(persisted.recordingSegments.count, 1)
        XCTAssertEqual(
            fixture.store.savedSnapshots.filter {
                $0.id == meetingID && $0.recordingSegments.count == 1
            }.count,
            1
        )
    }

    func testFailedPauseCheckpointBlocksResumeUntilSameCheckpointPersists() async throws {
        let fixture = makeFixture(pausedCheckpointFailures: 2)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        await fixture.viewModel.beginRecording()
        await fixture.viewModel.pauseActiveRecording()

        XCTAssertEqual(fixture.viewModel.screen, .paused)
        XCTAssertEqual(fixture.capture.startCount, 1)
        XCTAssertEqual(fixture.viewModel.meetings.first?.recordingSegments.count, 1)

        // The first retry still cannot persist. No second capture may start.
        await fixture.viewModel.resumeActiveRecording()
        XCTAssertEqual(fixture.viewModel.screen, .paused)
        XCTAssertEqual(fixture.capture.startCount, 1)

        fixture.store.pausedCheckpointFailuresRemaining = 0
        await fixture.viewModel.resumeActiveRecording()

        XCTAssertEqual(fixture.capture.startCount, 2)
        XCTAssertEqual(fixture.viewModel.screen, .recording)
        let persisted = try XCTUnwrap(fixture.store.loadMeetings().first)
        XCTAssertEqual(persisted.state, .recording)
        XCTAssertEqual(persisted.recordingSegments.map(\.sequence), [1])

        await fixture.viewModel.pauseActiveRecording()
    }

    func testTerminationIsRejectedUntilFinalCheckpointCanBePersisted() async throws {
        let fixture = makeFixture(finalCheckpointFailures: 2)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        await fixture.viewModel.beginRecording()
        let firstTerminationResult = await fixture.viewModel.prepareForTermination()

        // One failure occurs at finalization and one at the termination retry.
        XCTAssertFalse(firstTerminationResult)
        XCTAssertEqual(fixture.capture.stopCount, 1)

        fixture.store.finalCheckpointFailuresRemaining = 0
        let retryTerminationResult = await fixture.viewModel.prepareForTermination()

        XCTAssertTrue(retryTerminationResult)
        XCTAssertEqual(fixture.capture.stopCount, 1)
        let persisted = try XCTUnwrap(fixture.store.loadMeetings().first)
        XCTAssertEqual(persisted.state, .preparingAudio)
        XCTAssertEqual(persisted.recordingSegments.count, 1)
    }

    private func makeFixture(
        suspendStops: Bool = false,
        pausedCheckpointFailures: Int = 0,
        finalCheckpointFailures: Int = 0
    ) -> LifecycleFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileStore = LocalMeetingFileStore(rootURL: rootURL)
        let store = LifecycleMeetingStore(
            pausedCheckpointFailuresRemaining: pausedCheckpointFailures,
            finalCheckpointFailuresRemaining: finalCheckpointFailures
        )
        let capture = LifecycleCaptureService(suspendStops: suspendStops)
        let viewModel = MeetingViewModel(
            store: store,
            templateStore: MemorySummaryTemplateStore(),
            clipboard: MemoryClipboardService(),
            recordingSession: RecordingSession(captureService: capture, fileStore: fileStore),
            transcriptionService: TranscriptionService(
                whisperService: LifecycleWhisperService(),
                fileStore: fileStore
            ),
            summaryService: SummaryService(
                provider: LifecycleSummaryProvider(),
                fileStore: fileStore
            ),
            calendarService: LifecycleCalendarService(),
            reminderScheduler: LifecycleReminderScheduler(),
            fileStore: fileStore,
            resourcePreparer: LifecycleResourcePreparer()
        )
        return LifecycleFixture(
            rootURL: rootURL,
            store: store,
            capture: capture,
            viewModel: viewModel
        )
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
private struct LifecycleFixture {
    let rootURL: URL
    let store: LifecycleMeetingStore
    let capture: LifecycleCaptureService
    let viewModel: MeetingViewModel
}

@MainActor
private final class LifecycleMeetingStore: MeetingStore {
    private var meetings: [Meeting] = []
    var pausedCheckpointFailuresRemaining: Int
    var finalCheckpointFailuresRemaining: Int
    private(set) var savedSnapshots: [Meeting] = []

    init(
        pausedCheckpointFailuresRemaining: Int,
        finalCheckpointFailuresRemaining: Int
    ) {
        self.pausedCheckpointFailuresRemaining = pausedCheckpointFailuresRemaining
        self.finalCheckpointFailuresRemaining = finalCheckpointFailuresRemaining
    }

    func loadMeetings() throws -> [Meeting] {
        meetings
    }

    func save(_ meeting: Meeting) throws {
        savedSnapshots.append(meeting)
        if meeting.state == .paused,
           !meeting.recordingSegments.isEmpty,
           pausedCheckpointFailuresRemaining > 0 {
            pausedCheckpointFailuresRemaining -= 1
            throw LifecycleTestError.checkpointRejected
        }
        if meeting.state == .preparingAudio,
           !meeting.recordingSegments.isEmpty,
           finalCheckpointFailuresRemaining > 0 {
            finalCheckpointFailuresRemaining -= 1
            throw LifecycleTestError.checkpointRejected
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
private final class LifecycleCaptureService: AudioCaptureService {
    private var activeURL: URL?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private let suspendStops: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isStopWaiting = false

    init(suspendStops: Bool) {
        self.suspendStops = suspendStops
    }

    func requestPermissions() async throws {}

    func startSegment(at fileURL: URL) async throws {
        guard activeURL == nil else { throw RecordingError.alreadyRecording }
        activeURL = fileURL
        startCount += 1
    }

    func stopSegment() async throws -> CapturedAudio {
        guard let finishingURL = activeURL else { throw RecordingError.noActiveRecording }
        activeURL = nil
        stopCount += 1
        if suspendStops {
            isStopWaiting = true
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
            isStopWaiting = false
        }
        return CapturedAudio(fileURL: finishingURL, duration: 1)
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private enum LifecycleTestError: LocalizedError {
    case checkpointRejected

    var errorDescription: String? {
        "Falha simulada ao persistir checkpoint."
    }
}

private struct LifecycleWhisperService: WhisperService {
    func transcribe(segment: RecordingSegment) async throws -> String { "Áudio" }
}

private struct LifecycleSummaryProvider: SummaryProvider {
    func generateSummary(transcript: String, template: SummaryTemplate) async throws -> String {
        "# Resumo"
    }
}

@MainActor
private final class LifecycleCalendarService: GoogleCalendarServing {
    var isConfigured: Bool { false }
    func restoreAccount() async -> GoogleCalendarAccount? { nil }
    func connect() async throws -> GoogleCalendarAccount { throw GoogleCalendarError.missingConfiguration }
    func disconnect() async {}
    func upcomingEvents(from: Date, through: Date) async throws -> [CalendarEvent] { [] }
}

@MainActor
private final class LifecycleReminderScheduler: CalendarReminderScheduling {
    func scheduleReminders(for events: [CalendarEvent]) async {}
}

private struct LifecycleResourcePreparer: LocalResourcePreparing {
    func prepare() async throws {}
}
