import Foundation

@MainActor
public final class RecordingSession {
    private let captureService: AudioCaptureService
    private let fileStore: MeetingFileStore
    private var activeMeetingID: UUID?
    private var nextSequence = 1
    private var activeSegmentURL: URL?
    private var isStartingSegment = false
    private var isPausingSegment = false

    public private(set) var segments: [RecordingSegment] = []
    public var audioLevelHandler: ((AudioLevelSample) -> Void)?

    public init(captureService: AudioCaptureService, fileStore: MeetingFileStore = LocalMeetingFileStore()) {
        self.captureService = captureService
        self.fileStore = fileStore
        if let levelProvider = captureService as? AudioLevelProviding {
            levelProvider.setAudioLevelHandler { [weak self] sample in
                Task { @MainActor [weak self] in
                    self?.audioLevelHandler?(sample)
                }
            }
        }
    }

    public func start(meetingID: UUID) async throws {
        guard !isStartingSegment, !isPausingSegment else {
            throw RecordingError.alreadyRecording
        }
        guard activeSegmentURL == nil else { throw RecordingError.alreadyRecording }
        guard activeMeetingID == nil || activeMeetingID == meetingID else {
            throw RecordingError.captureFailed("Há outra reunião de gravação ativa.")
        }

        isStartingSegment = true
        defer { isStartingSegment = false }
        let isNewMeeting = activeMeetingID == nil
        let sequence = isNewMeeting ? 1 : nextSequence
        let url = try fileStore.makeSegmentURL(meetingID: meetingID, sequence: sequence)
        do {
            try await captureService.startSegment(at: url)
        } catch {
            // A failed resume must release the old logical meeting. Its
            // completed segments have already been returned and persisted by
            // the caller, while keeping this ID would block every later meeting.
            if !isNewMeeting {
                resetAfterCaptureFailure()
            }
            throw error
        }

        if isNewMeeting {
            activeMeetingID = meetingID
            nextSequence = 1
            segments = []
        }
        activeSegmentURL = url
    }

    public func pause() async throws -> RecordingSegment {
        guard !isStartingSegment, !isPausingSegment else {
            throw RecordingError.alreadyRecording
        }
        guard let meetingID = activeMeetingID, let url = activeSegmentURL else {
            throw RecordingError.noActiveRecording
        }

        isPausingSegment = true
        defer { isPausingSegment = false }
        let capturedAudio: CapturedAudio
        do {
            capturedAudio = try await captureService.stopSegment()
        } catch {
            // A capture service tears down its devices before finalizing the file.
            // Release the logical session as well so a failed export never blocks
            // the user from immediately starting another recording.
            resetAfterCaptureFailure()
            throw error
        }
        let segment = RecordingSegment(
            meetingID: meetingID,
            sequence: nextSequence,
            fileURL: capturedAudio.fileURL == url ? url : capturedAudio.fileURL,
            recordedDuration: capturedAudio.duration,
            captureWarning: capturedAudio.warning
        )
        segments.append(segment)
        nextSequence += 1
        activeSegmentURL = nil
        audioLevelHandler?(.silence)
        return segment
    }

    public func resume() async throws {
        guard let meetingID = activeMeetingID else { throw RecordingError.noActiveRecording }
        try await start(meetingID: meetingID)
    }

    public func finish() async throws -> [RecordingSegment] {
        guard !isStartingSegment, !isPausingSegment else {
            throw RecordingError.alreadyRecording
        }
        guard let meetingID = activeMeetingID else {
            throw RecordingError.noActiveRecording
        }

        // Detach the completed meeting before the potentially slow M4A export.
        // The capture coordinator stops the physical devices first, so a new
        // meeting can queue immediately while this meeting is finalized using
        // only the immutable snapshot below.
        let finishingURL = activeSegmentURL
        let finishingSequence = nextSequence
        var finishedSegments = segments
        activeSegmentURL = nil
        activeMeetingID = nil
        nextSequence = 1
        segments = []
        audioLevelHandler?(.silence)

        guard let finishingURL else { return finishedSegments }
        let capturedAudio = try await captureService.stopSegment()
        finishedSegments.append(RecordingSegment(
            meetingID: meetingID,
            sequence: finishingSequence,
            fileURL: capturedAudio.fileURL == finishingURL ? finishingURL : capturedAudio.fileURL,
            recordedDuration: capturedAudio.duration,
            captureWarning: capturedAudio.warning
        ))
        return finishedSegments
    }

    private func resetAfterCaptureFailure() {
        activeSegmentURL = nil
        activeMeetingID = nil
        nextSequence = 1
        segments = []
        audioLevelHandler?(.silence)
    }
}
