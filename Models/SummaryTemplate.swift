import Foundation

public struct SummaryTemplate: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let instructions: String
    public let sections: [String]
    public let sectionSubtopics: [String: [String]]?
    public let customStructure: String?
    public let isBuiltIn: Bool

    public var rawValue: String { displayName }
    public var isCustom: Bool { !isBuiltIn || id == Self.custom.id }

    public func subtopics(for section: String) -> [String] {
        sectionSubtopics?[section] ?? []
    }

    public var editableStructure: String {
        sections.flatMap { section -> [String] in
            [section] + subtopics(for: section).map { "\t- \($0)" }
        }.joined(separator: "\n")
    }

    public var promptStructure: String {
        sections.map { section in
            let subtopics = subtopics(for: section)
            guard !subtopics.isEmpty else { return "## \(section)" }
            return "## \(section)\nSubtópicos obrigatórios: " + subtopics.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    static let legacyStandardMeetingInstructions = "Produza um resumo objetivo e estritamente fiel à transcrição. Em Objetivo da reunião, descreva em uma frase clara a finalidade principal da conversa. Em Principais pontos abordados, use uma lista com marcadores: cada marcador deve representar um subtema e resumi-lo em uma única frase. Em Próximos passos, use uma lista com marcadores e informe o responsável somente quando ele puder ser identificado na transcrição; não deduza nomes, ações ou responsabilidades ausentes."
    static let previousStandardMeetingInstructions = "Produza um resumo aprofundado e estritamente fiel à transcrição, com volume proporcional ao conteúdo real da conversa. Em Objetivo da reunião, descreva em uma frase clara a finalidade principal. Em Principais pontos abordados, use uma lista com marcadores e cubra todos os subtemas relevantes, incluindo contexto, argumentos, decisões e justificativas, números, datas, riscos, pendências e divergências mencionadas; cada marcador deve ser uma frase informativa, sem repetição. Em Próximos passos, liste somente compromissos explícitos e preserve a ação, o prazo e o responsável quando estiverem identificados na transcrição; nunca deduza informações ausentes."

    public static let standardMeeting = SummaryTemplate(
        id: "standard-meeting",
        displayName: "Reunião Padrão",
        instructions: "Produza um resumo aprofundado em formato de ata executiva e estritamente fiel à transcrição, com volume proporcional ao conteúdo real da conversa. Descarte icebreakers, conversa social, testes de áudio, transições de apresentação, piadas e assuntos sem relação material com a pauta. Em Objetivo da reunião, registre em uma frase clara o contexto e a finalidade principal. Em Principais pontos abordados, use uma lista com marcadores e cubra todos os subtemas relevantes, incluindo argumentos, decisões e acordos confirmados, justificativas, números, datas, riscos, pendências e divergências; diferencie fatos de hipóteses e propostas de decisões, e escreva cada evidência uma única vez. Em Próximos passos, liste somente compromissos explícitos pós-reunião e preserve a ação, o responsável e o prazo quando estiverem identificados na transcrição; nunca deduza informações ausentes.",
        sections: ["Objetivo da reunião", "Principais pontos abordados", "Próximos passos"],
        isBuiltIn: true
    )

    public static let oneOnOne = SummaryTemplate(
        id: "one-on-one",
        displayName: "1:1",
        instructions: "Registre esta conversa individual de forma concisa e acionável. Dê ênfase às prioridades imediatas, ao progresso, aos desafios e ao feedback pessoal. Em Topo da pauta, traga a questão mais urgente. Em Atualizações e conquistas, destaque avanços recentes. Em Desafios e bloqueios, registre obstáculos. Em Feedback mútuo, separe com clareza o feedback dado e recebido. Em Próximo marco, indique ações, responsáveis e prazos explicitamente mencionados.",
        sections: ["Topo da pauta", "Atualizações e conquistas", "Desafios e bloqueios", "Feedback mútuo", "Próximo marco"],
        isBuiltIn: true
    )

    public static let customerDiscovery = SummaryTemplate(
        id: "customer-discovery",
        displayName: "Descoberta de cliente",
        instructions: "Resuma a conversa com um cliente potencial para apoiar o entendimento de suas necessidades, preocupações e objetivos. Priorize o que o cliente disse, não a fala de quem conduziu a reunião. Preserve números e citações úteis sem inventar informações. Em Contexto do cliente, registre negócio, setor e função. Em Dores e necessidades, detalhe problemas e resultados desejados. Em Perguntas ou preocupações, reúna dúvidas e objeções. Em Orçamento e cronograma, destaque valores e datas. Em Próximos passos, indique acompanhamentos, responsáveis e prazos.",
        sections: ["Contexto do cliente", "Dores e necessidades", "Perguntas ou preocupações", "Orçamento e cronograma", "Próximos passos"],
        isBuiltIn: true
    )

    public static let hiring = SummaryTemplate(
        id: "hiring",
        displayName: "Contratação",
        instructions: "Organize a entrevista com foco na adequação da pessoa candidata à vaga. Em Trajetória profissional, registre formação, funções, responsabilidades e realizações. Em Competências e experiências, destaque habilidades técnicas e comportamentais pertinentes. Em Motivação e aderência, registre objetivos de carreira e interesse pela função e empresa. Em Disponibilidade e pretensão salarial, detalhe aviso prévio, data possível de início e expectativas mencionadas. Em Minhas observações, inclua apenas observações explícitas do entrevistador; caso não existam, escreva N/A. Em Próximos passos, registre as etapas seguintes e considerações de prazo.",
        sections: ["Trajetória profissional", "Competências e experiências", "Motivação e aderência", "Disponibilidade e pretensão salarial", "Minhas observações", "Próximos passos"],
        isBuiltIn: true
    )

    public static let accountManagement = SummaryTemplate(
        id: "account-management",
        displayName: "Gestão de contas",
        instructions: "Resuma a conversa com uma conta estratégica para compreender necessidades, padrões de uso, oportunidades de expansão e riscos de retenção. Em Uso atual e satisfação, registre como o produto é utilizado, quantidade de usuários, casos de uso e percepção de valor. Em Necessidades adicionais e dores, detalhe lacunas e dificuldades. Em Planos futuros, registre projetos, expansões ou contratações que possam afetar o uso. Em Próximos passos acordados, indique ações de cada parte, responsáveis, prazos e acompanhamentos.",
        sections: ["Uso atual e satisfação", "Necessidades adicionais e dores", "Planos futuros", "Próximos passos acordados"],
        isBuiltIn: true
    )

    public static let existingCustomer = SummaryTemplate(
        id: "existing-customer",
        displayName: "Cliente existente",
        instructions: "Resuma a conversa com um cliente existente para registrar o impacto real do produto, feedback acionável e oportunidades de evolução da relação. Em Satisfação atual, registre experiências positivas e pontos de atrito. Em Uso recente e resultados, descreva como o produto vem sendo usado e os resultados obtidos. Em Desafios e necessidades de suporte, documente problemas, pedidos de ajuda e melhorias solicitadas. Em Oportunidades e próximos passos, registre expansão, venda adicional, fortalecimento da relação e ações acordadas.",
        sections: ["Satisfação atual", "Uso recente e resultados", "Desafios e necessidades de suporte", "Oportunidades e próximos passos"],
        isBuiltIn: true
    )

    public static let customerOnboarding = SummaryTemplate(
        id: "customer-onboarding",
        displayName: "Onboarding de cliente",
        instructions: "Resuma a sessão de onboarding com foco nas circunstâncias do novo cliente, reações iniciais e preocupações. Não detalhe o produto do apresentador salvo quando necessário para dar contexto a uma decisão. Em Informações essenciais, registre setor, objetivos e forma pretendida de uso. Em Perguntas e preocupações, reúna dúvidas, esclarecimentos e riscos percebidos. Em Cronograma e próximos passos, registre marcos, ações, responsáveis e prazos acordados.",
        sections: ["Informações essenciais", "Perguntas e preocupações", "Cronograma e próximos passos"],
        isBuiltIn: true
    )

    public static let troubleshooting = SummaryTemplate(
        id: "troubleshooting",
        displayName: "Solução de problemas",
        instructions: "Registre com precisão o atendimento a um cliente que enfrentou problemas com um produto ou serviço. Em Desafio ou problema, descreva sintomas, contexto e detalhes fornecidos. Em Soluções sugeridas e resultados, liste os passos executados ou propostos e os resultados observados. Em Próximos passos, registre ações adicionais, responsáveis e prazos de acompanhamento.",
        sections: ["Desafio ou problema", "Soluções sugeridas e resultados", "Próximos passos"],
        isBuiltIn: true
    )

    public static let projectSync = SummaryTemplate(
        id: "project-sync",
        displayName: "Sincronização de projeto",
        instructions: "Resuma a sincronização do projeto para mostrar a situação atual, o que vem a seguir, os obstáculos e o alinhamento do time. Em Status do projeto, registre avanços, entregas e marcos concluídos desde a última conversa. Em Bloqueios atuais, detalhe impedimentos e propostas discutidas. Em Próximas tarefas e marcos, indique prioridades, responsáveis e prazos. Em Colaboração do time e itens de ação, registre papéis, decisões de colaboração e novas ações atribuídas.",
        sections: ["Status do projeto", "Bloqueios atuais", "Próximas tarefas e marcos", "Colaboração do time e itens de ação"],
        isBuiltIn: true
    )

    public static let custom = SummaryTemplate(
        id: "custom",
        displayName: "Personalizado",
        instructions: "Organize uma ata executiva conforme as seções configuradas, respeitando literalmente seus títulos e sua ordem. Preserve objetividade e fidelidade à transcrição, descarte conversa social ou sem relação com a pauta, diferencie propostas de decisões confirmadas e só registre responsáveis e prazos quando estiverem explícitos.",
        sections: ["Resumo", "Pontos relevantes", "Próximos passos"],
        customStructure: "",
        isBuiltIn: true
    )

    public static let general = standardMeeting
    public static let productDiscovery = customerDiscovery
    public static let refinement = projectSync
    public static let daily = projectSync

    public static let allCases: [SummaryTemplate] = [
        .standardMeeting, .oneOnOne, .customerDiscovery, .hiring, .accountManagement,
        .existingCustomer, .customerOnboarding, .troubleshooting, .projectSync,
        .custom
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
        let parsed = Self.parseStructure(trimmed)

        return SummaryTemplate(
            id: id,
            displayName: displayName,
            instructions: instructions,
            sections: parsed.sections.isEmpty ? sections : parsed.sections,
            sectionSubtopics: parsed.sections.isEmpty ? sectionSubtopics : parsed.subtopics,
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
        sectionSubtopics: [String: [String]]? = nil,
        customStructure: String? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.instructions = instructions
        self.sections = sections
        self.sectionSubtopics = sectionSubtopics
        self.customStructure = customStructure
        self.isBuiltIn = isBuiltIn
    }
}

public extension SummaryTemplate {
    var snapshotValue: String {
        let snapshot = SummaryTemplateSnapshot(
            id: id,
            displayName: displayName,
            instructions: instructions,
            sections: sections,
            sectionSubtopics: sectionSubtopics,
            isBuiltIn: isBuiltIn
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return sections.joined(separator: "\n")
        }
        return Self.snapshotV3Prefix + data.base64EncodedString()
    }

    func applyingSnapshot(_ value: String) -> SummaryTemplate {
        let prefix: String
        if value.hasPrefix(Self.snapshotV3Prefix) {
            prefix = Self.snapshotV3Prefix
        } else if value.hasPrefix(Self.snapshotV2Prefix) {
            prefix = Self.snapshotV2Prefix
        } else {
            return personalized(with: value)
        }
        let encoded = String(value.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded),
              let snapshot = try? JSONDecoder().decode(SummaryTemplateSnapshot.self, from: data) else {
            return self
        }
        return SummaryTemplate(
            id: snapshot.id ?? id,
            displayName: snapshot.displayName ?? displayName,
            instructions: snapshot.instructions,
            sections: snapshot.sections,
            sectionSubtopics: snapshot.sectionSubtopics,
            customStructure: value,
            isBuiltIn: snapshot.isBuiltIn ?? isBuiltIn
        )
    }

    /// Recreates the exact template used by a meeting without requiring that
    /// template to still exist in the editable library. Version 2 snapshots
    /// predate persisted names, so they retain the library name when one is
    /// available and otherwise receive an explicit historical placeholder.
    static func restoringSnapshot(
        _ value: String,
        templateID: String,
        fallback: SummaryTemplate? = nil
    ) -> SummaryTemplate {
        let base = fallback
            ?? SummaryTemplate(id: templateID)
            ?? SummaryTemplate(
                id: templateID,
                displayName: "Template histórico",
                instructions: SummaryTemplate.custom.instructions,
                sections: SummaryTemplate.custom.sections,
                customStructure: value,
                isBuiltIn: false
            )
        let restored = base.applyingSnapshot(value)

        // The meeting record owns the template identifier. Keep that stable
        // even if a malformed or mismatched snapshot is encountered.
        guard restored.id != templateID else { return restored }
        return SummaryTemplate(
            id: templateID,
            displayName: restored.displayName,
            instructions: restored.instructions,
            sections: restored.sections,
            sectionSubtopics: restored.sectionSubtopics,
            customStructure: restored.customStructure,
            isBuiltIn: restored.isBuiltIn
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

        var normalizedSubtopics: [String: [String]] = [:]
        for section in normalizedSections {
            let values = subtopics(for: section)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty {
                normalizedSubtopics[section] = values
            }
        }

        return SummaryTemplate(
            id: id,
            displayName: name,
            instructions: directions,
            sections: normalizedSections,
            sectionSubtopics: normalizedSubtopics.isEmpty ? nil : normalizedSubtopics,
            customStructure: customStructure,
            isBuiltIn: isBuiltIn
        )
    }

    static func parseSections(_ value: String) -> [String] {
        parseStructure(value).sections
    }

    static func parseStructure(
        _ value: String
    ) -> (sections: [String], subtopics: [String: [String]]) {
        let expanded = value.replacingOccurrences(of: ";", with: "\n")
        var sections: [String] = []
        var subtopics: [String: [String]] = [:]
        var currentSection: String?

        for rawLine in expanded.components(separatedBy: .newlines) {
            guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let startsWithTab = rawLine.hasPrefix("\t")
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let startsWithDash = trimmed.hasPrefix("-")
            var content = trimmed
            if startsWithDash {
                content.removeFirst()
                content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !content.isEmpty else { continue }

            if (startsWithTab || startsWithDash), let currentSection {
                subtopics[currentSection, default: []].append(content)
            } else {
                sections.append(content)
                currentSection = content
            }
        }
        return (sections, subtopics)
    }

    private static let snapshotV2Prefix = "qapia-template-v2:"
    private static let snapshotV3Prefix = "qapia-template-v3:"
}

private struct SummaryTemplateSnapshot: Codable {
    let id: String?
    let displayName: String?
    let instructions: String
    let sections: [String]
    let sectionSubtopics: [String: [String]]?
    let isBuiltIn: Bool?
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
