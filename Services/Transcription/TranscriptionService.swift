import Foundation

public enum TranscriptionError: LocalizedError, Sendable, Equatable {
    case noSegments

    public var errorDescription: String? {
        "Não há segmentos de áudio para transcrever."
    }
}

public struct TranscriptionService: Sendable {
    private let whisperService: any WhisperService
    private let fileStore: any MeetingFileStore

    public init(
        whisperService: any WhisperService,
        fileStore: any MeetingFileStore = LocalMeetingFileStore()
    ) {
        self.whisperService = whisperService
        self.fileStore = fileStore
    }

    public func transcribe(
        meetingID: UUID,
        segments: [RecordingSegment]
    ) async throws -> String {
        let orderedSegments = segments.sorted { $0.sequence < $1.sequence }
        guard !orderedSegments.isEmpty else { throw TranscriptionError.noSegments }

        var transcripts: [String] = []
        for segment in orderedSegments {
            let transcript = try await whisperService.transcribe(segment: segment)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw WhisperError.emptyTranscript }
            transcripts.append(transcript)
        }

        let transcript = transcripts.joined(separator: "\n\n")
        try fileStore.writeTranscript(transcript, meetingID: meetingID)
        return transcript
    }
}
