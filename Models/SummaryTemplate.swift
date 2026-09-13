import Foundation

public struct SummaryTemplate: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let instructions: String
    public let sections: [String]
    public let customStructure: String?
    public let isBuiltIn: Bool

    public var rawValue: String { displayName }
    public var isCustom: Bool { !isBuiltIn || id == Self.custom.id }

    public static let general = SummaryTemplate(
        id: "general",
        displayName: "Reunião Geral",
        instructions: "Produza uma visão executiva objetiva, destacando decisões, responsáveis e prazos explicitamente mencionados.",
        sections: [
            "Resumo executivo", "Assuntos discutidos", "Decisões", "Pendências",
            "Próximos passos", "Responsáveis", "Prazos"
        ],
        isBuiltIn: true
    )

    public static let productDiscovery = SummaryTemplate(
        id: "product-discovery",
        displayName: "Product Discovery",
        instructions: "Organize aprendizados sobre problemas, necessidades e oportunidades sem transformar hipóteses em fatos.",
        sections: [
            "Contexto", "Problemas", "Necessidades", "Insights",
            "Feature requests", "Decisões", "Próximos passos"
        ],
        isBuiltIn: true
    )

    public static let refinement = SummaryTemplate(
        id: "refinement",
        displayName: "Refinamento",
        instructions: "Priorize requisitos, regras de negócio, dependências, riscos e pendências técnicas mencionadas.",
        sections: [
            "Contexto", "Requisitos", "Regras de negócio", "Dependências",
            "Riscos", "Pendências", "Próximos passos"
        ],
        isBuiltIn: true
    )

    public static let daily = SummaryTemplate(
        id: "daily",
        displayName: "Daily",
        instructions: "Resuma atualizações por assunto e destaque bloqueios e ações seguintes de forma curta.",
        sections: ["Atualizações", "Bloqueios", "Pendências", "Próximos passos"],
        isBuiltIn: true
    )

    public static let custom = SummaryTemplate(
        id: "custom",
        displayName: "Personalizado",
        instructions: "Organize o conteúdo conforme as seções configuradas, preservando objetividade e fidelidade à transcrição.",
        sections: ["Resumo", "Pontos relevantes", "Próximos passos"],
        customStructure: "",
        isBuiltIn: true
    )

    public static let allCases: [SummaryTemplate] = [
        .general, .productDiscovery, .refinement, .daily, .custom
    ]

    public init?(id: String) {
        guard let template = Self.allCases.first(where: {
            $0.id == id || $0.displayName == id
        }) else { return nil }
        self = template
    }

    public init?(rawValue: String) {
        self.init(id: rawValue)
    }

    public func personalized(with structure: String) -> SummaryTemplate {
        let trimmed = structure.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedSections = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return SummaryTemplate(
            id: id,
            displayName: displayName,
            instructions: instructions,
            sections: parsedSections.isEmpty ? sections : parsedSections,
            customStructure: trimmed,
            isBuiltIn: isBuiltIn
        )
    }

    public static func == (lhs: SummaryTemplate, rhs: SummaryTemplate) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public init(
        id: String,
        displayName: String,
        instructions: String,
        sections: [String],
        customStructure: String? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.instructions = instructions
        self.sections = sections
        self.customStructure = customStructure
        self.isBuiltIn = isBuiltIn
    }
}

public extension SummaryTemplate {
    var snapshotValue: String {
        let snapshot = SummaryTemplateSnapshot(instructions: instructions, sections: sections)
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return sections.joined(separator: "\n")
        }
        return "qapia-template-v2:" + data.base64EncodedString()
    }

    func applyingSnapshot(_ value: String) -> SummaryTemplate {
        let prefix = "qapia-template-v2:"
        guard value.hasPrefix(prefix) else {
            return personalized(with: value)
        }
        let encoded = String(value.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded),
              let snapshot = try? JSONDecoder().decode(SummaryTemplateSnapshot.self, from: data) else {
            return self
        }
        return SummaryTemplate(
            id: id,
            displayName: displayName,
            instructions: snapshot.instructions,
            sections: snapshot.sections,
            customStructure: value,
            isBuiltIn: isBuiltIn
        )
    }

    func validated() throws -> SummaryTemplate {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let directions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSections = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !name.isEmpty else { throw SummaryTemplateValidationError.missingName }
        guard name.count <= 60 else { throw SummaryTemplateValidationError.nameTooLong }
        guard !directions.isEmpty else { throw SummaryTemplateValidationError.missingInstructions }
        guard !normalizedSections.isEmpty else { throw SummaryTemplateValidationError.missingSections }
        guard normalizedSections.count <= 15 else { throw SummaryTemplateValidationError.tooManySections }

        var seen = Set<String>()
        let hasDuplicate = normalizedSections.contains { section in
            let key = section.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return !seen.insert(key).inserted
        }
        guard !hasDuplicate else { throw SummaryTemplateValidationError.duplicateSections }

        return SummaryTemplate(
            id: id,
            displayName: name,
            instructions: directions,
            sections: normalizedSections,
            customStructure: customStructure,
            isBuiltIn: isBuiltIn
        )
    }

    static func parseSections(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct SummaryTemplateSnapshot: Codable {
    let instructions: String
    let sections: [String]
}

public enum SummaryTemplateValidationError: LocalizedError, Equatable {
    case missingName
    case nameTooLong
    case missingInstructions
    case missingSections
    case tooManySections
    case duplicateSections

    public var errorDescription: String? {
        switch self {
        case .missingName: "Informe um nome para o template."
        case .nameTooLong: "Use um nome com até 60 caracteres."
        case .missingInstructions: "Descreva como o resumo deve ser produzido."
        case .missingSections: "Adicione pelo menos uma seção ao resumo."
        case .tooManySections: "Use no máximo 15 seções."
        case .duplicateSections: "Remova as seções repetidas."
        }
    }
}
