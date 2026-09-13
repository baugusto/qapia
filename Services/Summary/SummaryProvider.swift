import Foundation

public protocol SummaryProvider: Sendable {
    func generateSummary(
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String
}

public enum SummaryProviderError: LocalizedError, Sendable, Equatable {
    case emptyTranscript
    case emptySummary
    case onDeviceModelUnavailable
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "A transcrição está vazia e não pode ser resumida."
        case .emptySummary:
            return "O modelo local não produziu um resumo. Tente novamente."
        case .onDeviceModelUnavailable:
            return "O modelo Ollama local ainda não está disponível. Verifique a preparação dos recursos e tente novamente."
        case let .generationFailed(message):
            return "Não foi possível gerar o resumo local: \(message)"
        }
    }
}
