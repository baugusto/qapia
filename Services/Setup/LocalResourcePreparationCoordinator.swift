import Combine
import Foundation

public enum ApplicationSetupPhase: Equatable, Sendable {
    case idle
    case checking
    case preparingTranscription
    case ready
    case failed(String)

    public var displayName: String {
        switch self {
        case .idle, .checking:
            return "Verificando recursos locais"
        case .preparingTranscription:
            return "Preparando transcrição local"
        case .ready:
            return "Recursos locais prontos"
        case .failed:
            return "A preparação precisa de atenção"
        }
    }

    public var detail: String {
        switch self {
        case .idle, .checking:
            return "O QAP.ia está verificando os recursos locais necessários."
        case .preparingTranscription:
            return "Baixando e validando o modelo de transcrição. Isso acontece somente na primeira utilização."
        case .ready:
            return "A transcrição local está pronta. Os resumos permanecem neste Mac."
        case let .failed(message):
            return message
        }
    }
}

@MainActor
public final class ApplicationSetupStatus: ObservableObject {
    public static let shared = ApplicationSetupStatus()

    @Published public private(set) var phase: ApplicationSetupPhase = .idle

    private init() {}

    func update(_ phase: ApplicationSetupPhase) {
        self.phase = phase
    }
}

public protocol LocalResourcePreparing: Sendable {
    func prepare() async throws
}

public actor LocalResourcePreparationCoordinator: LocalResourcePreparing {
    public static let shared = LocalResourcePreparationCoordinator()

    private let whisperModelStore: WhisperModelStore
    private var preparationTask: Task<Void, Error>?

    public init(
        whisperModelStore: WhisperModelStore = .shared
    ) {
        self.whisperModelStore = whisperModelStore
    }

    public func prepare() async throws {
        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task { [whisperModelStore] in
            await ApplicationSetupStatus.shared.update(.checking)
            do {
                await ApplicationSetupStatus.shared.update(.preparingTranscription)
                _ = try await whisperModelStore.preparedModelURL()

                await ApplicationSetupStatus.shared.update(.ready)
            } catch {
                await ApplicationSetupStatus.shared.update(.failed(error.localizedDescription))
                throw error
            }
        }
        preparationTask = task

        do {
            try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }
}
