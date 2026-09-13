import Foundation

public protocol WhisperService: Sendable {
    func transcribe(segment: RecordingSegment) async throws -> String
    func transcribeWithDiagnostics(segment: RecordingSegment) async throws -> WhisperTranscriptionResult
    func finishTranscriptionBatch()
}

public struct WhisperTranscriptionResult: Sendable, Equatable {
    public let transcript: String
    public let warnings: [String]

    public init(transcript: String, warnings: [String] = []) {
        self.transcript = transcript
        self.warnings = warnings
    }
}

public extension WhisperService {
    func transcribeWithDiagnostics(segment: RecordingSegment) async throws -> WhisperTranscriptionResult {
        WhisperTranscriptionResult(transcript: try await transcribe(segment: segment))
    }

    /// Releases resources that are useful across pause/resume segments but
    /// should not remain resident while the summary model is running.
    func finishTranscriptionBatch() {}
}

public enum WhisperError: LocalizedError, Sendable, Equatable {
    case transcriptionFailed(String)
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case let .transcriptionFailed(message):
            return "O Whisper não conseguiu transcrever este segmento: \(message)"
        case .emptyTranscript:
            return "Nenhuma fala audível foi encontrada no áudio gravado."
        }
    }
}
