import Foundation
import XCTest
@testable import QapiaCore

final class OllamaSummaryIntegrationTests: XCTestCase {
    func testModelSelectionPrefersHigherQualityCompatibleLocalModel() {
        XCTAssertEqual(
            OllamaClient.preferredModel(
                from: ["gemma3:1b", "qwen3.5:4b", "qwen3.5:9b"],
                physicalMemoryBytes: 24 * 1_073_741_824
            ),
            "qwen3.5:9b"
        )
        XCTAssertEqual(
            OllamaClient.preferredModel(
                from: ["nomic-embed-text:latest", "modelo-local:latest"],
                physicalMemoryBytes: 8 * 1_073_741_824
            ),
            "modelo-local:latest"
        )
        XCTAssertNil(OllamaClient.preferredModel(
            from: ["nomic-embed-text:latest"],
            physicalMemoryBytes: 8 * 1_073_741_824
        ))
    }

    func testRecommendedQwenModelFitsUnifiedMemoryTier() {
        XCTAssertEqual(
            OllamaModelPolicy.recommendedModel(physicalMemoryBytes: 8 * 1_073_741_824),
            "qwen3.5:2b-q4_K_M"
        )
        XCTAssertEqual(
            OllamaModelPolicy.recommendedModel(physicalMemoryBytes: 16 * 1_073_741_824),
            "qwen3.5:4b-q4_K_M"
        )
        XCTAssertEqual(
            OllamaModelPolicy.recommendedModel(physicalMemoryBytes: 24 * 1_073_741_824),
            "qwen3.5:9b-q4_K_M"
        )
        XCTAssertEqual(
            OllamaModelPolicy.recommendedModel(physicalMemoryBytes: 64 * 1_073_741_824),
            "qwen3.5:27b-q4_K_M"
        )
    }

    func testUnavailableOllamaIsSurfacedInsteadOfReturningTranscriptExcerpts() async throws {
        let provider = OnDeviceSummaryProvider(
            resourcePreparer: PreparedOllamaResources(),
            ollamaProvider: OllamaSummaryProvider(client: UnavailableOllama())
        )

        do {
            _ = try await provider.generateSummary(
                transcript: "A equipe decidiu adiar a entrega. Marina enviará o plano amanhã.",
                template: .standardMeeting
            )
            XCTFail("O produto não deve substituir uma falha da LLM por trechos da transcrição.")
        } catch let error as SummaryProviderError {
            XCTAssertEqual(
                error,
                .generationFailed("O modelo de teste está indisponível.")
            )
        }
    }

    func testExecutiveQualityGateRejectsLiteralTranscriptCollage() {
        let transcript = """
        O objetivo da reunião é avaliar a prontidão do portal para o lançamento nacional planejado.
        A telemetria mostrou lentidão persistente no processamento dos pedidos durante os testes de carga.
        A análise técnica relacionou a lentidão ao índice desatualizado da base principal de clientes.
        """
        let literal = """
        ## Objetivo da reunião

        O objetivo da reunião é avaliar a prontidão do portal para o lançamento nacional planejado.

        ## Principais pontos abordados

        - A telemetria mostrou lentidão persistente no processamento dos pedidos durante os testes de carga.

        ## Próximos passos

        Não informado na transcrição
        """
        let synthesis = """
        ## Objetivo da reunião

        Avaliar se o portal reúne condições para o lançamento nacional.

        ## Principais pontos abordados

        - Os testes de carga indicaram lentidão no processamento, associada tecnicamente ao índice desatualizado da base de clientes.

        ## Próximos passos

        Não informado na transcrição
        """

        XCTAssertFalse(ExecutiveSynthesisQualityValidator.isExecutiveSynthesis(
            literal,
            comparedWith: transcript,
            template: .standardMeeting
        ))
        XCTAssertTrue(ExecutiveSynthesisQualityValidator.isExecutiveSynthesis(
            synthesis,
            comparedWith: transcript,
            template: .standardMeeting
        ))
    }

    func testDirectValidationAllowsExecutiveParaphraseAndRejectsInventedAnchors() {
        let transcript = """
        A equipe analisou a prontidão do portal. Marina confirmou que enviará o plano amanhã.
        """
        let synthesis = """
        ## Objetivo da reunião

        Avaliar as condições do portal para a continuidade do trabalho.

        ## Principais pontos abordados

        - O grupo revisou a situação atual do portal e alinhou a necessidade de um plano.

        ## Próximos passos

        - Enviar o plano — Responsável: Marina — Prazo: amanhã
        """
        let inventedDeadline = synthesis.replacingOccurrences(
            of: "amanhã",
            with: "12 dias"
        )

        XCTAssertTrue(DirectSummaryValidator.isValid(
            synthesis,
            sourceTranscript: transcript,
            template: .standardMeeting
        ))
        XCTAssertFalse(DirectSummaryValidator.isValid(
            inventedDeadline,
            sourceTranscript: transcript,
            template: .standardMeeting
        ))
    }

    func testRealTranscriptProducesExecutiveMinutesWithOllamaWhenRequested() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment[
            "QAPIA_OLLAMA_SUMMARY_FIXTURE"
        ] else {
            throw XCTSkip("Defina QAPIA_OLLAMA_SUMMARY_FIXTURE para validar o Ollama local.")
        }

        let transcript = try String(
            contentsOf: URL(fileURLWithPath: fixturePath),
            encoding: .utf8
        )
        let template: SummaryTemplate = ProcessInfo.processInfo.environment[
            "QAPIA_OLLAMA_SUMMARY_TEMPLATE"
        ] == "one-on-one" ? .oneOnOne : .standardMeeting
        let summary = try await OllamaSummaryProvider().generateSummary(
            transcript: transcript,
            template: template
        )

        let headings = summary.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("## ") }
            .map { String($0.dropFirst(3)) }
        let summaryWordCount = summary.split(whereSeparator: \.isWhitespace).count
        let transcriptWordCount = transcript.split(whereSeparator: \.isWhitespace).count

        XCTAssertEqual(headings, template.sections)
        let conciseLimit = transcriptWordCount >= 1_200
            ? transcriptWordCount / 3
            : 350
        XCTAssertLessThan(summaryWordCount, min(1_200, conciseLimit))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("Monjara"))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("cão terranos"))
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("precisa de trocar aqui"))
        if ProcessInfo.processInfo.environment["QAPIA_SUMMARY_PRINT"] == "1" {
            print("\n=== QAPIA OLLAMA EXECUTIVE MINUTES ===\n\(summary.prefix(4_000))\n=== END QAPIA OLLAMA EXECUTIVE MINUTES ===\n")
        }
    }
}

private struct PreparedOllamaResources: SummaryResourcePreparing {
    func prepare() async throws {}
}

private struct UnavailableOllama: OllamaGenerating {
    func preferredInstalledModel() async throws -> String {
        throw SummaryProviderError.generationFailed("O modelo de teste está indisponível.")
    }

    func generate(
        model: String,
        system: String,
        prompt: String,
        maximumOutputTokens: Int
    ) async throws -> String {
        XCTFail("A geração não deve ser chamada sem modelo disponível.")
        return ""
    }
}
