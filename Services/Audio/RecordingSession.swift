import Foundation

@MainActor
public final class RecordingSession {
    private let captureService: AudioCaptureService
    private let fileStore: MeetingFileStore
    private var activeMeetingID: UUID?
    private var nextSequence = 1
    private var activeSegmentURL: URL?

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
        guard activeSegmentURL == nil else { throw RecordingError.alreadyRecording }
        guard activeMeetingID == nil || activeMeetingID == meetingID else {
            throw RecordingError.captureFailed("Há outra reunião de gravação ativa.")
        }

        try await captureService.requestPermissions()
        let isNewMeeting = activeMeetingID == nil
        let sequence = isNewMeeting ? 1 : nextSequence
        let url = try fileStore.makeSegmentURL(meetingID: meetingID, sequence: sequence)
        try await captureService.startSegment(at: url)

        if isNewMeeting {
            activeMeetingID = meetingID
            nextSequence = 1
            segments = []
        }
        activeSegmentURL = url
    }

    public func pause() async throws -> RecordingSegment {
        guard let meetingID = activeMeetingID, let url = activeSegmentURL else {
            throw RecordingError.noActiveRecording
        }

        let capturedAudio = try await captureService.stopSegment()
        let segment = RecordingSegment(
            meetingID: meetingID,
            sequence: nextSequence,
            fileURL: capturedAudio.fileURL == url ? url : capturedAudio.fileURL,
            recordedDuration: capturedAudio.duration
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
        if activeSegmentURL != nil {
            _ = try await pause()
        }
        guard activeMeetingID != nil else { throw RecordingError.noActiveRecording }
        activeMeetingID = nil
        return segments
    }
}
