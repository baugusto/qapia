import Combine
import Foundation

public enum ApplicationSetupPhase: Equatable, Sendable {
    case idle
    case checking
    case preparingTranscription
    case preparingSummaryRuntime
    case preparingSummaryModel(String)
    case ready
    case failed(String)

    public var displayName: String {
        switch self {
        case .idle, .checking:
            return "Verificando recursos locais"
        case .preparingTranscription:
            return "Preparando transcrição local"
        case .preparingSummaryRuntime:
            return "Preparando inteligência local"
        case .preparingSummaryModel:
            return "Preparando modelo de resumo"
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
            return "Baixando e validando o modelo de transcrição quando necessário."
        case .preparingSummaryRuntime:
            return "Verificando e instalando o mecanismo Ollama local quando necessário."
        case let .preparingSummaryModel(model):
            return "Baixando e validando \(model). O resumo continuará inteiramente neste Mac."
        case .ready:
            return "A transcrição e o modelo de resumo local estão prontos."
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

public struct LegacyTranscriptionVocabularyMigration: Sendable {
    public enum Outcome: Equatable, Sendable {
        case removed
        case alreadyAbsent
        case preservedNonFile
        case failed
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Qapia/Transcription/vocabulary.json")
    }

    private let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    @discardableResult
    public func run() -> Outcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ) else {
            return .alreadyAbsent
        }
        guard !isDirectory.boolValue else { return .preservedNonFile }

        do {
            try FileManager.default.removeItem(at: fileURL)
            return .removed
        } catch {
            // Obsolete settings must never prevent audio/model preparation.
            return .failed
        }
    }
}

public actor LocalResourcePreparationCoordinator: LocalResourcePreparing {
    public static let shared = LocalResourcePreparationCoordinator()

    private let whisperModelStore: WhisperModelStore
    private let summaryResourcePreparer: any SummaryResourcePreparing
    private let legacyVocabularyMigration: LegacyTranscriptionVocabularyMigration
    private var preparationTask: Task<Void, Error>?

    public init(
        whisperModelStore: WhisperModelStore = .shared,
        summaryResourcePreparer: any SummaryResourcePreparing = OllamaResourcePreparationCoordinator.shared,
        legacyVocabularyFileURL: URL = LegacyTranscriptionVocabularyMigration.defaultFileURL
    ) {
        self.whisperModelStore = whisperModelStore
        self.summaryResourcePreparer = summaryResourcePreparer
        self.legacyVocabularyMigration = LegacyTranscriptionVocabularyMigration(
            fileURL: legacyVocabularyFileURL
        )
    }

    public func prepare() async throws {
        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task { [whisperModelStore, summaryResourcePreparer, legacyVocabularyMigration] in
            await ApplicationSetupStatus.shared.update(.checking)
            await ApplicationPrerequisiteStatus.shared.beginPreparation()
            do {
                legacyVocabularyMigration.run()
                await ApplicationSetupStatus.shared.update(.preparingTranscription)
                do {
                    _ = try await whisperModelStore.preparedModelURL()
                    await ApplicationPrerequisiteStatus.shared.markWhisperReady()
                } catch {
                    await ApplicationPrerequisiteStatus.shared.markWhisperFailed(
                        error.localizedDescription
                    )
                    throw error
                }

                await ApplicationSetupStatus.shared.update(.preparingSummaryRuntime)
                let model = OllamaModelPreference.selectedChoice().modelName
                await ApplicationPrerequisiteStatus.shared.beginSummaryPreparation(model: model)
                await ApplicationSetupStatus.shared.update(.preparingSummaryModel(model))
                do {
                    try await summaryResourcePreparer.prepare()
                    await ApplicationPrerequisiteStatus.shared.markSummaryReady(model: model)
                } catch {
                    await ApplicationPrerequisiteStatus.shared.markSummaryFailed(
                        error,
                        model: model
                    )
                    throw error
                }

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
