import Foundation

public enum MeetingState: String, CaseIterable, Codable, Identifiable, Sendable {
    case idle
    case recording
    case paused
    case preparingAudio
    case transcribing
    case transcribed
    case summarizing
    case completed
    case failed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .idle: return "Pronto"
        case .recording: return "Gravando"
        case .paused: return "Pausado"
        case .preparingAudio: return "Preparando áudio"
        case .transcribing: return "Transcrevendo"
        case .transcribed: return "Transcrição concluída"
        case .summarizing: return "Gerando resumo"
        case .completed: return "Concluído"
        case .failed: return "Falhou"
        }
    }
}

public enum QapiaScreen: String, CaseIterable, Codable, Identifiable, Sendable {
    case empty
    case settings
    case recording
    case paused
    case processing
    case meetingDetail

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .empty: return "Empty"
        case .settings: return "Settings"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .processing: return "Processing"
        case .meetingDetail: return "Meeting Detail"
        }
    }
}

public enum MeetingDetailTab: String, CaseIterable, Identifiable, Sendable {
    case summary
    case transcript

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .summary: return "Resumo"
        case .transcript: return "Transcrição"
        }
    }
}

public enum CopyFeedback: String, Sendable {
    case idle
    case copied
}
