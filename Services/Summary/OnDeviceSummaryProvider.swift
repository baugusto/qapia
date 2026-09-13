import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Produces summaries without downloading or running code outside QAP.ia.
/// On macOS 26 and later, it uses the system's on-device Apple Intelligence
/// model when available. All other Macs receive an extractive local summary.
public struct OnDeviceSummaryProvider: SummaryProvider, Sendable {
    private let fallback: ExtractiveSummaryProvider

    public init(fallback: ExtractiveSummaryProvider = .init()) {
        self.fallback = fallback
    }

    public func generateSummary(
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String {
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTranscript.isEmpty else { throw SummaryProviderError.emptyTranscript }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                return try await AppleIntelligenceSummaryProvider().generateSummary(
                    transcript: cleanTranscript,
                    template: template
                )
            } catch {
                // A deterministic fallback keeps the core workflow available on
                // Macs where Apple Intelligence is disabled or temporarily busy.
            }
        }
        #endif

        return try await fallback.generateSummary(transcript: cleanTranscript, template: template)
    }
}

public struct ExtractiveSummaryProvider: SummaryProvider, Sendable {
    public init() {}

    public func generateSummary(
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String {
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTranscript.isEmpty else { throw SummaryProviderError.emptyTranscript }

        let sentences = Self.sentences(in: cleanTranscript)
        guard !sentences.isEmpty else { throw SummaryProviderError.emptySummary }

        let sections = template.sections.map { section in
            let matches = Self.matches(for: section, sentences: sentences)
            let content = matches.isEmpty
                ? "Não informado na transcrição"
                : matches.map { "- \($0.element)" }.joined(separator: "\n")
            return "## \(section)\n\n\(content)"
        }

        return sections.joined(separator: "\n\n")
    }

    private static func sentences(in transcript: String) -> [String] {
        transcript
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
    }

    private static func matches(
        for section: String,
        sentences: [String]
    ) -> [(offset: Int, element: String)] {
        let normalizedSection = section.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let keywords = keywords(for: normalizedSection)

        let candidates = sentences.enumerated().filter { _, sentence in
            let normalizedSentence = sentence.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return keywords.contains { normalizedSentence.contains($0) }
        }

        if !candidates.isEmpty {
            return Array(candidates.prefix(4))
        }

        if normalizedSection.contains("resumo") || normalizedSection.contains("assunto") || normalizedSection.contains("contexto") {
            return Array(sentences.enumerated().prefix(3))
        }

        return []
    }

    private static func keywords(for section: String) -> [String] {
        if section.contains("decis") { return ["decid", "aprov", "acord", "defin", "combin"] }
        if section.contains("pend") || section.contains("bloque") || section.contains("risco") {
            return ["pendent", "bloque", "risco", "depend", "aguard", "falta"]
        }
        if section.contains("proximo") || section.contains("acao") {
            return ["proximo", "vamos", "vai ", "iremos", "deve", "acao", "enviar", "fazer"]
        }
        if section.contains("respons") { return ["respons", "dono", "vai ", "deve", "ficou"] }
        if section.contains("prazo") { return ["prazo", "hoje", "amanha", "segunda", "terca", "quarta", "quinta", "sexta", "data"] }
        if section.contains("requisito") || section.contains("regra") { return ["requis", "regra", "precisa", "deve", "criterio"] }
        if section.contains("necess") || section.contains("problema") { return ["necess", "problema", "dor", "dificuldade"] }
        if section.contains("insight") || section.contains("feature") { return ["insight", "ideia", "feature", "oportunidade"] }
        if section.contains("atualiz") { return ["feito", "conclu", "andamento", "trabalh", "atualiz"] }
        return []
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private struct AppleIntelligenceSummaryProvider {
    func generateSummary(transcript: String, template: SummaryTemplate) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw SummaryProviderError.onDeviceModelUnavailable }

        let session = LanguageModelSession(model: model, instructions: SummaryPrompt.system)
        let response = try await session.respond(to: SummaryPrompt.user(
            transcript: TranscriptReducer.reduce(transcript),
            template: template
        ))
        let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw SummaryProviderError.emptySummary }
        return summary
    }
}
#endif

private enum TranscriptReducer {
    static func reduce(_ transcript: String, limit: Int = 11_000) -> String {
        guard transcript.count > limit else { return transcript }
        let sentences = transcript.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        var output = ""
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let candidate = output.isEmpty ? trimmed : output + ". " + trimmed
            guard candidate.count <= limit else { break }
            output = candidate
        }
        return output.isEmpty ? String(transcript.prefix(limit)) : output
    }
}
