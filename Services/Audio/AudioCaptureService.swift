import Foundation

public struct CapturedAudio: Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    public let warning: String?

    public init(fileURL: URL, duration: TimeInterval, warning: String? = nil) {
        self.fileURL = fileURL
        self.duration = duration
        self.warning = warning
    }
}

public struct AudioLevelSample: Sendable, Equatable {
    public let microphone: Float
    public let system: Float

    public init(microphone: Float, system: Float) {
        self.microphone = min(max(microphone.isFinite ? microphone : 0, 0), 1)
        self.system = min(max(system.isFinite ? system : 0, 0), 1)
    }

    public var combined: Float {
        max(microphone, system)
    }

    public static let silence = AudioLevelSample(microphone: 0, system: 0)
}

public enum RecordingError: LocalizedError, Sendable, Equatable {
    case microphonePermissionDenied
    case systemAudioPermissionDenied
    case microphoneUnavailable
    case alreadyRecording
    case noActiveRecording
    case captureFailed(String)
    case fileWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "O acesso ao microfone foi negado. Autorize o QAP.ia em Ajustes do Sistema."
        case .systemAudioPermissionDenied:
            return "A captura de áudio do sistema foi negada. Autorize o áudio do sistema para o QAP.ia em Privacidade e Segurança."
        case .microphoneUnavailable:
            return "Nenhum microfone disponível foi encontrado."
        case .alreadyRecording:
            return "Já existe uma gravação em andamento."
        case .noActiveRecording:
            return "Não há gravação em andamento para encerrar."
        case let .captureFailed(message), let .fileWriteFailed(message):
            return message
        }
    }
}

@MainActor
public protocol AudioCaptureService: AnyObject {
    func requestPermissions() async throws
    func startSegment(at fileURL: URL) async throws
    func stopSegment() async throws -> CapturedAudio
}

@MainActor
public protocol AudioLevelProviding: AnyObject {
    func setAudioLevelHandler(_ handler: (@Sendable (AudioLevelSample) -> Void)?)
}
