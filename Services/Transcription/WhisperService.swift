import Foundation

public protocol WhisperService: Sendable {
    func transcribe(segment: RecordingSegment) async throws -> String
}

public enum WhisperError: LocalizedError, Sendable, Equatable {
    case transcriptionFailed(String)
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case let .transcriptionFailed(message):
            return "O Whisper não conseguiu transcrever este segmento: \(message)"
        case .emptyTranscript:
            return "O Whisper terminou sem retornar texto para este segmento."
        }
    }
}
