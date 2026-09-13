import Foundation

public enum TranscriptionError: LocalizedError, Sendable, Equatable {
    case noSegments
    case noUsableSegments([Int])

    public var errorDescription: String? {
        switch self {
        case .noSegments:
            "Não há segmentos de áudio para transcrever."
        case let .noUsableSegments(sequences):
            "Nenhum segmento pôde ser transcrito. Verifique o áudio dos segmentos \(sequences.map(String.init).joined(separator: ", "))."
        }
    }
}

public struct MeetingTranscriptionResult: Sendable, Equatable {
    public let transcript: String
    public let segmentWarnings: [Int: [String]]

    public init(transcript: String, segmentWarnings: [Int: [String]] = [:]) {
        self.transcript = transcript
        self.segmentWarnings = segmentWarnings
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
        let result = try await generateTranscript(segments: segments)
        try Task.checkCancellation()
        try fileStore.writeTranscript(result.transcript, meetingID: meetingID)
        return result.transcript
    }

    public func generateTranscript(
        segments: [RecordingSegment]
    ) async throws -> MeetingTranscriptionResult {
        let orderedSegments = segments.sorted { $0.sequence < $1.sequence }
        guard !orderedSegments.isEmpty else { throw TranscriptionError.noSegments }
        defer { whisperService.finishTranscriptionBatch() }

        var transcripts: [String] = []
        var failedSequences: [Int] = []
        var segmentWarnings: [Int: [String]] = [:]
        for segment in orderedSegments {
            try Task.checkCancellation()
            do {
                let result = try await whisperService.transcribeWithDiagnostics(segment: segment)
                let transcript = result.transcript
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.warnings.isEmpty {
                    segmentWarnings[segment.sequence, default: []].append(
                        contentsOf: result.warnings
                    )
                }
                // A pause/resume boundary can legitimately produce a segment
                // that contains only silence.
                if !transcript.isEmpty {
                    transcripts.append(transcript)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // One damaged pause/resume segment must not discard speech
                // recovered from the rest of the meeting.
                failedSequences.append(segment.sequence)
            }
        }

        guard !transcripts.isEmpty else {
            if failedSequences.isEmpty { throw WhisperError.emptyTranscript }
            throw TranscriptionError.noUsableSegments(failedSequences)
        }

        if !failedSequences.isEmpty {
            let list = failedSequences.sorted().map(String.init).joined(separator: ", ")
            let subject = failedSequences.count == 1 ? "o segmento" : "os segmentos"
            let verb = failedSequences.count == 1 ? "não pôde" : "não puderam"
            transcripts.append(
                "[Aviso do QAP.ia: \(subject) \(list) \(verb) ser transcrito; os demais foram preservados.]"
            )
        }
        let transcript = transcripts.joined(separator: "\n\n")
        return MeetingTranscriptionResult(
            transcript: transcript,
            segmentWarnings: segmentWarnings
        )
    }
}
