import XCTest
@testable import QapiaCore

final class SummaryDepthRegressionTests: XCTestCase {
    private let provider = ExtractiveSummaryProvider()

    func testHardWrappedTranscriptProducesCompleteSentences() async throws {
        let transcript = """
        O objetivo da reunião é alinhar a entrega
        do módulo fiscal com a equipe técnica.
        A integração depende da homologação
        do cliente prevista para 14 de setembro.
        Marina vai enviar o cronograma final até sexta-feira.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertEqual(
            section(named: "Objetivo da reunião", in: summary),
            "O objetivo da reunião é alinhar a entrega do módulo fiscal com a equipe técnica."
        )
        XCTAssertTrue(
            section(named: "Principais pontos abordados", in: summary)
                .contains("A integração depende da homologação do cliente prevista para 14 de setembro."),
            summary
        )
        XCTAssertFalse(summary.contains("alinhar a entrega\n"), summary)
        XCTAssertFalse(summary.contains("homologação\n"), summary)
    }

    func testStandardMeetingCoversAtLeastSixGroundedFactsAndPreservesCriticalQualifiers() async throws {
        let transcript = """
        O objetivo da reunião foi avaliar, com profundidade, a prontidão do Projeto Aurora para a liberação nacional, reunindo evidências de operação, segurança, experiência do cliente, custos e riscos antes de qualquer decisão definitiva.
        A telemetria mostrou redução de 37% no tempo mediano de processamento durante quatro semanas completas, incluindo picos de segunda-feira e operações simultâneas nas regiões Sul, Sudeste e Nordeste.
        Os testes com 128 sessões reais confirmaram que o fluxo de cadastro permaneceu estável, mesmo quando cada participante alternou entre conexões corporativas, redes residenciais e acesso móvel durante a mesma jornada.
        A auditoria técnica não encontrou perda de dados em nenhuma das 128 sessões observadas, e o resultado negativo para corrupção foi revisado separadamente pelas equipes de qualidade e segurança.
        A equipe registrou como hipótese ainda não confirmada que o aumento de 240 milissegundos esteja ligado ao DNS do fornecedor, portanto esse risco permanece em investigação e não foi apresentado como causa comprovada.
        O contrato atual limita o custo adicional a R$ 480.000 por ano, condiciona qualquer ampliação a uma aprovação jurídica formal e proíbe a ativação automática de serviços fora do território brasileiro.
        O ensaio de recuperação restaurou 96% das operações em menos de sete minutos, mas quatro casos antigos exigiram intervenção manual porque os registros haviam sido criados antes da adoção do novo formato de armazenamento.
        A revisão de privacidade confirmou que nenhum áudio deixou os computadores avaliados, que todos os arquivos permaneceram criptografados localmente e que as permissões concedidas estavam limitadas aos recursos efetivamente usados durante o teste.
        O estudo de acessibilidade encontrou contraste adequado em onze das doze telas avaliadas, enquanto a tela de recuperação ainda apresentou uma mensagem ambígua para participantes que utilizavam o leitor de tela em português.
        O plano de liberação separa a adoção em três grupos controlados e condiciona a passagem entre eles à estabilidade das integrações, ao volume de suporte e à conclusão das verificações independentes.
        O principal risco operacional é concluir a homologação até 30 de setembro, porque três integrações bancárias ainda dependem de certificados emitidos por organizações externas ao projeto.
        A dependência da API Atlas foi isolada por uma camada de contingência que mantém as consultas essenciais por vinte minutos, mas o mecanismo ainda precisa ser observado sob carga máxima antes da liberação.
        Na pesquisa moderada, 42 de 50 participantes preferiram a nova navegação, enquanto oito solicitaram maior contraste nos estados de erro e textos mais claros durante a recuperação de uma sessão interrompida.
        O suporte registrou queda de 18% nos chamados repetidos depois da mudança, embora os casos relacionados a certificados continuem exigindo atendimento manual e tenham tempo de resolução acima da meta acordada.
        A equipe jurídica explicou que a expansão internacional somente poderá ser reavaliada depois da conclusão do relatório de impacto, da revisão das cláusulas de privacidade e da aprovação formal do comitê executivo.
        Marina vai enviar o relatório consolidado com as evidências revisadas até 18 de setembro de 2026, sem alterar os resultados negativos ou converter a hipótese do DNS em uma conclusão definitiva.
        Rafael deverá validar 37 cenários de contingência e apresentar as divergências documentadas na próxima reunião, mantendo separadas as medições confirmadas e as explicações que ainda dependem de investigação.
        """

        XCTAssertGreaterThan(
            transcript.split(whereSeparator: { $0.isWhitespace }).count,
            400,
            "O fixture precisa continuar representando uma transcrição longa."
        )

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )
        let mainPoints = section(named: "Principais pontos abordados", in: summary)
        let mainBullets = bullets(in: mainPoints)

        XCTAssertGreaterThanOrEqual(mainBullets.count, 6, summary)

        let factualAnchors = [
            "37%", "128 sessões", "não encontrou perda de dados",
            "hipótese ainda não confirmada", "R$ 480.000", "30 de setembro",
            "API Atlas", "42 de 50", "18%", "expansão internacional"
        ]
        let coveredFacts = factualAnchors.filter(mainPoints.contains)
        XCTAssertGreaterThanOrEqual(
            coveredFacts.count,
            6,
            "Cobertura insuficiente: \(coveredFacts).\n\(summary)"
        )

        XCTAssertTrue(summary.contains("Marina"), summary)
        XCTAssertTrue(summary.contains("37 cenários"), summary)
        XCTAssertTrue(summary.contains("18 de setembro de 2026"), summary)
        XCTAssertTrue(summary.contains("não encontrou perda de dados"), summary)
        XCTAssertTrue(summary.contains("hipótese ainda não confirmada"), summary)
        XCTAssertTrue(summary.contains("não foi apresentado como causa comprovada"), summary)
    }

    func testNextStepsContainOnlyExplicitCommitments() async throws {
        let transcript = """
        O objetivo da conversa é revisar o andamento do relatório trimestral.
        Vamos começar pela apresentação dos indicadores consolidados.
        Será que Carla poderia enviar uma versão preliminar?
        Talvez Pedro possa validar os anexos antes da publicação.
        Carla vai enviar o relatório aprovado até sexta-feira.
        Pedro deverá validar os anexos finais em 12 de setembro.
        Luciana publicará a ata definitiva em 15 de setembro.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )
        let nextSteps = section(named: "Próximos passos", in: summary)

        XCTAssertEqual(bullets(in: nextSteps).count, 3, summary)
        XCTAssertTrue(nextSteps.contains("Carla vai enviar o relatório aprovado até sexta-feira."), summary)
        XCTAssertTrue(nextSteps.contains("Pedro deverá validar os anexos finais em 12 de setembro."), summary)
        XCTAssertTrue(nextSteps.contains("Luciana publicará a ata definitiva em 15 de setembro."), summary)
        XCTAssertFalse(nextSteps.contains("Vamos começar"), summary)
        XCTAssertFalse(nextSteps.contains("Será que"), summary)
        XCTAssertFalse(nextSteps.contains("Talvez"), summary)
    }

    func testCommitmentIsNeverConsumedByMainPointsWhenItIsTheOnlyRemainingFact() async throws {
        let transcript = """
        O objetivo da reunião é alinhar o fechamento mensal.
        Marina vai enviar o relatório aprovado até sexta-feira.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertEqual(
            section(named: "Principais pontos abordados", in: summary),
            "Não informado na transcrição",
            summary
        )
        XCTAssertTrue(
            section(named: "Próximos passos", in: summary)
                .contains("Marina vai enviar o relatório aprovado até sexta-feira."),
            summary
        )
    }

    func testImmediatePresentationTransitionsAreNotNextSteps() async throws {
        let transcript = """
        O objetivo da reunião é revisar o relatório operacional.
        Vamos revisar este item agora.
        Vamos analisar a próxima tela.
        Apresentaremos o próximo ponto.
        Carla vai revisar o contrato até sexta-feira.
        Marina apresentará o próximo ponto ao comitê até quinta-feira.
        Carlos vai revisar o próximo tópico amanhã.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )
        let nextSteps = section(named: "Próximos passos", in: summary)

        XCTAssertEqual(bullets(in: nextSteps).count, 3, summary)
        XCTAssertTrue(nextSteps.contains("Carla vai revisar o contrato até sexta-feira."), summary)
        XCTAssertTrue(nextSteps.contains("Marina apresentará o próximo ponto"), summary)
        XCTAssertTrue(nextSteps.contains("Carlos vai revisar o próximo tópico amanhã."), summary)
        XCTAssertFalse(nextSteps.contains("agora"), summary)
        XCTAssertFalse(nextSteps.contains("próxima tela"), summary)
        XCTAssertFalse(nextSteps.contains("Apresentaremos o próximo ponto."), summary)
    }

    func testPresentTenseOperationalStatementsAreNotFutureCommitments() async throws {
        let transcript = """
        O objetivo da reunião é revisar a rotina operacional.
        A equipe prepara relatórios mensalmente.
        O sistema libera a versão automaticamente.
        Ele retira duplicatas durante o processamento.
        Luciana publicará a ata definitiva.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )
        let nextSteps = section(named: "Próximos passos", in: summary)

        XCTAssertEqual(bullets(in: nextSteps).count, 1, summary)
        XCTAssertTrue(nextSteps.contains("Luciana publicará a ata definitiva."), summary)
        XCTAssertFalse(nextSteps.contains("prepara relatórios"), summary)
        XCTAssertFalse(nextSteps.contains("libera a versão"), summary)
        XCTAssertFalse(nextSteps.contains("retira duplicatas"), summary)
    }

    func testForecastsNegatedAndConditionalStatementsAreNotActionsWhileAssignmentsRemain() async throws {
        let transcript = """
        O objetivo da reunião é revisar o plano de lançamento.
        A receita vai crescer vinte por cento no próximo trimestre.
        A inadimplência deve cair depois da mudança de política.
        A Acme vai crescer vinte por cento no próximo trimestre.
        As vendas vão crescer vinte por cento no próximo trimestre.
        As vendas crescerão vinte por cento no próximo trimestre.
        A equipe vai crescer vinte por cento neste ano.
        A equipe vai aumentar vinte por cento neste ano.
        A gerente vai sair de férias na próxima semana.
        A gerente sairá de férias na próxima semana.
        Carla continuará doente durante a próxima semana.
        O sistema vai falhar novamente se a carga aumentar.
        O produto vai melhorar bastante na próxima versão.
        Carla não vai publicar a versão nesta semana.
        Se o contrato for aprovado, Carla vai publicar a versão até sexta-feira.
        Carla vai enviar o relatório caso a diretoria aprove o orçamento.
        Carla vai publicar a versão quando receber a aprovação jurídica.
        Bruno ficou responsável por acompanhar o cliente durante a próxima semana.
        A versão será publicada por Carla até sexta-feira.
        A Acme vai enviar o contrato amanhã.
        Marina vai confirmar se o arquivo chegou amanhã.
        Carla vai continuar monitorando os erros até sexta-feira.
        Bruno vai melhorar a documentação amanhã.
        Ana vai aumentar o limite do banco até amanhã.
        Paulo vai diminuir o custo da infraestrutura nesta semana.
        Carla vai ficar responsável por acompanhar o cliente.
        Eu cuidarei do relatório amanhã.
        Carla entregará o arquivo até sexta-feira.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )
        let nextSteps = section(named: "Próximos passos", in: summary)

        XCTAssertEqual(bullets(in: nextSteps).count, 11, summary)
        XCTAssertTrue(
            nextSteps.contains("Bruno ficou responsável por acompanhar o cliente durante a próxima semana."),
            summary
        )
        XCTAssertTrue(
            nextSteps.contains("A versão será publicada por Carla até sexta-feira."),
            summary
        )
        XCTAssertTrue(nextSteps.contains("A Acme vai enviar o contrato amanhã."), summary)
        XCTAssertTrue(nextSteps.contains("Marina vai confirmar se o arquivo chegou amanhã."), summary)
        XCTAssertTrue(nextSteps.contains("Carla vai continuar monitorando os erros até sexta-feira."), summary)
        XCTAssertTrue(nextSteps.contains("Bruno vai melhorar a documentação amanhã."), summary)
        XCTAssertTrue(nextSteps.contains("Ana vai aumentar o limite do banco até amanhã."), summary)
        XCTAssertTrue(nextSteps.contains("Paulo vai diminuir o custo da infraestrutura nesta semana."), summary)
        XCTAssertTrue(nextSteps.contains("Carla vai ficar responsável por acompanhar o cliente."), summary)
        XCTAssertTrue(nextSteps.contains("Eu cuidarei do relatório amanhã."), summary)
        XCTAssertTrue(nextSteps.contains("Carla entregará o arquivo até sexta-feira."), summary)
        XCTAssertFalse(nextSteps.contains("receita vai crescer"), summary)
        XCTAssertFalse(nextSteps.contains("inadimplência deve cair"), summary)
        XCTAssertFalse(nextSteps.contains("A Acme vai crescer"), summary)
        XCTAssertFalse(nextSteps.contains("As vendas vão crescer"), summary)
        XCTAssertFalse(nextSteps.contains("As vendas crescerão"), summary)
        XCTAssertFalse(nextSteps.contains("A equipe vai crescer"), summary)
        XCTAssertFalse(nextSteps.contains("A equipe vai aumentar vinte por cento"), summary)
        XCTAssertFalse(nextSteps.contains("A gerente vai sair de férias"), summary)
        XCTAssertFalse(nextSteps.contains("A gerente sairá de férias"), summary)
        XCTAssertFalse(nextSteps.contains("Carla continuará doente"), summary)
        XCTAssertFalse(nextSteps.contains("O sistema vai falhar"), summary)
        XCTAssertFalse(nextSteps.contains("O produto vai melhorar"), summary)
        XCTAssertFalse(nextSteps.contains("Carla não vai publicar"), summary)
        XCTAssertFalse(nextSteps.contains("Se o contrato for aprovado"), summary)
        XCTAssertFalse(nextSteps.contains("caso a diretoria aprove"), summary)
        XCTAssertFalse(nextSteps.contains("quando receber a aprovação"), summary)
    }

    func testAccountGrowthPlanIsNotMisrepresentedAsAnAgreedAction() async throws {
        let transcript = """
        A conta utiliza o produto diariamente com cinquenta usuários e declarou satisfação com a estabilidade.
        O cliente relatou lentidão no cadastro de novos usuários.
        O cliente vai crescer para cem usuários no próximo trimestre.
        Nenhuma ação foi acordada durante a conversa.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .accountManagement
        )

        XCTAssertTrue(
            section(named: "Planos futuros", in: summary)
                .contains("O cliente vai crescer para cem usuários no próximo trimestre."),
            summary
        )
        XCTAssertEqual(
            section(named: "Próximos passos acordados", in: summary),
            "Não informado na transcrição",
            summary
        )
    }

    func testEditedTemplateInstructionsChangeExtractivePriority() async throws {
        let transcript = """
        A Plataforma Atlas processou 84 solicitações críticas sem interrupção durante a janela principal.
        A auditoria confirmou ausência de perda de dados em todos os lotes avaliados pela equipe.
        O relatório técnico registrou três riscos de segurança que continuam sob investigação independente.
        A operação regional preservou os prazos acordados mesmo durante o aumento inesperado da demanda.
        O suporte resolveu 42 incidentes complexos dentro da meta contratual estabelecida para o trimestre.
        Os custos de energia solar permaneceram dentro do orçamento previsto para a operação piloto.
        A diretoria aprovou a expansão controlada depois da revisão jurídica e financeira do contrato.
        A equipe confirmou que o plano de contingência respondeu corretamente aos cenários simulados.
        O cliente Valid informou melhora consistente na experiência das pessoas responsáveis pelo cadastro.
        A análise final encontrou duas dependências externas que podem afetar a próxima etapa da entrega.
        """
        let plainTemplate = SummaryTemplate(
            id: "plain-focus",
            displayName: "Síntese",
            instructions: "Priorize os fatos relevantes da operação.",
            sections: ["Principais pontos abordados"]
        )
        let focusedTemplate = SummaryTemplate(
            id: "solar-focus",
            displayName: "Síntese solar",
            instructions: "Priorize orçamento, custos e energia solar.",
            sections: ["Principais pontos abordados"]
        )

        let plain = try await provider.generateSummary(
            transcript: transcript,
            template: plainTemplate
        )
        let focused = try await provider.generateSummary(
            transcript: transcript,
            template: focusedTemplate
        )

        XCTAssertNotEqual(plain, focused)
        XCTAssertTrue(focused.contains("custos de energia solar"), focused)
    }

    func testObjectivePrefersStandaloneMeetingThemeOverDependentDetail() async throws {
        let transcript = """
        A reunião examina a crise institucional e as regras aplicáveis à investigação em curso.
        Porque aqui há um ponto específico sobre a autorização concedida ao relator do processo.
        O relatório apresentou evidências documentais e divergências entre as instituições envolvidas.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertEqual(
            section(named: "Objetivo da reunião", in: summary),
            "A reunião examina a crise institucional e as regras aplicáveis à investigação em curso.",
            summary
        )
    }

    func testQapiaCaptureWarningIsNeverSummarized() async throws {
        let transcript = """
        [Aviso do QAP.ia: o microfone ficou temporariamente indisponível e a captura foi preservada.]
        O objetivo da reunião é avaliar a entrega do portal.
        A equipe confirmou que o portal processou 84 pedidos sem perda de dados.
        Joana vai revisar o relatório final amanhã.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertFalse(summary.localizedCaseInsensitiveContains("Aviso do QAP.ia"), summary)
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("microfone ficou temporariamente"), summary)
        XCTAssertTrue(summary.contains("84 pedidos"), summary)
    }

    func testNormalizedDuplicateFactsAppearOnlyOnce() async throws {
        let transcript = """
        O objetivo da reunião é revisar a estabilidade do serviço.
        O sistema registrou 42 eventos críticos durante a janela de manutenção.
        o sistema registrou   42 eventos críticos durante a janela de manutenção.
        O SISTEMA REGISTROU 42 EVENTOS CRÍTICOS DURANTE A JANELA DE MANUTENÇÃO.
        A análise confirmou que todos os eventos tiveram a mesma origem documentada.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertEqual(
            occurrences(of: "42 eventos críticos", in: summary.lowercased()),
            1,
            summary
        )
    }

    func testTranscriptReducerPreservesBeginningAndEndSentinelsBeyondElevenThousandCharacters() {
        let beginning = "SENTINELA INICIAL registra o objetivo original e deve permanecer."
        let middle = (0..<260).map { index in
            "O bloco factual \(index) documenta uma evidência independente, com contexto operacional suficiente para representar uma parte distinta da conversa."
        }.joined(separator: " ")
        let ending = "SENTINELA FINAL registra a decisão derradeira e deve permanecer."
        let transcript = "\(beginning) \(middle) \(ending)"

        XCTAssertGreaterThan(transcript.count, 11_000)

        let reduced = TranscriptReducer.reduce(transcript)

        XCTAssertLessThanOrEqual(reduced.count, 11_000)
        XCTAssertTrue(reduced.contains("SENTINELA INICIAL"), reduced)
        XCTAssertTrue(reduced.contains("SENTINELA FINAL"), reduced)
    }

    func testTranscriptReducerPrioritizesDecisionRiskAndCommitmentAcrossLongMeeting() {
        let neutralPrefix = (0..<45).map { index in
            "O registro \(alphabeticToken(index)) descreve uma observação contextual neutra sobre o fluxo cotidiano da conversa."
        }.joined(separator: " ")
        let critical = """
        A equipe decidiu bloquear a liberação até a conclusão da auditoria independente.
        O risco central é a perda de dados durante a migração do cadastro legado.
        Marina vai enviar o relatório de segurança até sexta-feira.
        """
        let neutralSuffix = (45..<110).map { index in
            "O registro \(alphabeticToken(index)) descreve uma observação contextual neutra sobre o fluxo cotidiano da conversa."
        }.joined(separator: " ")
        let transcript = "SENTINELA INICIAL apresenta o contexto original. \(neutralPrefix) \(critical) \(neutralSuffix) SENTINELA FINAL encerra a conversa."

        XCTAssertGreaterThan(transcript.count, 4_000)
        let reduced = TranscriptReducer.reduce(transcript, limit: 1_500)

        XCTAssertLessThanOrEqual(reduced.count, 1_500)
        XCTAssertTrue(reduced.contains("SENTINELA INICIAL"), reduced)
        XCTAssertTrue(reduced.contains("decidiu bloquear a liberação"), reduced)
        XCTAssertTrue(reduced.contains("risco central é a perda de dados"), reduced)
        XCTAssertTrue(reduced.contains("Marina vai enviar o relatório"), reduced)
        XCTAssertTrue(reduced.contains("SENTINELA FINAL"), reduced)
    }

    func testLongExtractiveRankingStopsPromptlyAfterCancellation() async throws {
        let transcript = (0..<1_500).map { index in
            "O registro \(alphabeticToken(index)) documenta um aspecto independente da operação, seus efeitos observados e o contexto necessário para análise."
        }.joined(separator: " ")
        let task = Task.detached(priority: .background) {
            try await ExtractiveSummaryProvider().generateSummary(
                transcript: transcript,
                template: .standardMeeting
            )
        }

        try await Task.sleep(nanoseconds: 2_000_000)
        let cancellationStartedAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("O ranking longo deveria respeitar o cancelamento.")
        } catch is CancellationError {
            // Expected: a new recording must not wait for summary ranking.
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(cancellationStartedAt),
            0.5,
            "O cancelamento do resumo demorou e poderia atrasar uma nova gravação."
        )
    }

    func testAudioCheckQuestionNeverBecomesMeetingObjective() async throws {
        let transcript = """
        Vocês estão me ouvindo bem?
        O objetivo da reunião é decidir a estratégia de lançamento do Projeto Aurora.
        A equipe comparou os riscos das duas alternativas comerciais apresentadas.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertEqual(
            section(named: "Objetivo da reunião", in: summary),
            "O objetivo da reunião é decidir a estratégia de lançamento do Projeto Aurora.",
            summary
        )
        XCTAssertFalse(summary.contains("ouvindo bem"), summary)
    }

    func testMeaningfulObjectiveBeginningWithVamosEntenderIsPreserved() async throws {
        let transcript = """
        Vamos entender a causa do incidente que derrubou o sistema e definir o escopo da investigação.
        A indisponibilidade afetou 84 sessões durante a manhã.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertEqual(
            section(named: "Objetivo da reunião", in: summary),
            "Vamos entender a causa do incidente que derrubou o sistema e definir o escopo da investigação.",
            summary
        )
    }

    func testDefaultCustomTemplateSummaryExecutiveReceivesTheMeetingTheme() async throws {
        let template = SummaryTemplate(
            id: "custom-draft",
            displayName: "Template personalizado",
            instructions: "Em Resumo executivo, registre o contexto central. Em Decisões, registre apenas decisões confirmadas. Em Próximos passos, registre compromissos explícitos.",
            sections: ["Resumo executivo", "Decisões", "Próximos passos"]
        )
        let transcript = """
        A reunião avaliou a prontidão do portal para a liberação nacional.
        A diretoria decidiu manter a homologação por mais uma semana.
        Marina vai enviar o relatório final até sexta-feira.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: template
        )

        XCTAssertEqual(
            section(named: "Resumo executivo", in: summary),
            "A reunião avaliou a prontidão do portal para a liberação nacional.",
            summary
        )
        XCTAssertTrue(section(named: "Decisões", in: summary).contains("decidiu manter"), summary)
        XCTAssertTrue(section(named: "Próximos passos", in: summary).contains("Marina vai enviar"), summary)
    }

    func testCustomSectionGuidanceDoesNotCrossContaminateSections() async throws {
        let template = SummaryTemplate(
            id: "business-review",
            displayName: "Revisão de negócio",
            instructions: "Em Financeiro, destaque receitas e margem. Em Pessoas, destaque contratações e retenção.",
            sections: ["Financeiro", "Pessoas"]
        )
        let transcript = """
        A receita recorrente cresceu 18% e a margem permaneceu acima da meta trimestral.
        A empresa contratou três engenheiros e manteve a retenção do time no período.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: template
        )
        let financial = section(named: "Financeiro", in: summary)
        let people = section(named: "Pessoas", in: summary)

        XCTAssertTrue(financial.contains("receita recorrente"), summary)
        XCTAssertFalse(financial.contains("três engenheiros"), summary)
        XCTAssertTrue(people.contains("três engenheiros"), summary)
        XCTAssertFalse(people.contains("receita recorrente"), summary)
    }

    func testShortCriticalBudgetFactIsNotDiscardedByLengthFilter() async throws {
        let transcript = """
        O objetivo da reunião é avaliar a viabilidade operacional do programa nacional.
        A equipe técnica concluiu uma análise detalhada das integrações e confirmou estabilidade durante toda a janela de observação.
        O suporte acompanhou usuários de três regiões e documentou melhorias consistentes na conclusão do cadastro assistido.
        A auditoria externa revisou os controles de acesso e não encontrou perda de dados nos cenários avaliados.
        O orçamento aprovado é R$ 500.000.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertTrue(
            section(named: "Principais pontos abordados", in: summary)
                .contains("O orçamento aprovado é R$ 500.000."),
            summary
        )
    }

    func testDiscoveryTemplateUnderstandsFactsWithoutRepeatingSectionVocabulary() async throws {
        let transcript = """
        A Acme desenvolve próteses ortopédicas em Recife.
        Cada entrega consome quatorze dias e algumas cirurgias são suspensas.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .customerDiscovery
        )

        XCTAssertTrue(
            section(named: "Contexto do cliente", in: summary).contains("A Acme desenvolve"),
            summary
        )
        XCTAssertTrue(
            section(named: "Dores e necessidades", in: summary).contains("quatorze dias"),
            summary
        )
    }

    func testFactualAudioProblemIsNotMistakenForSoundCheckFiller() async throws {
        let transcript = """
        O objetivo da reunião é investigar falhas encontradas nas gravações recentes.
        O teste de áudio confirmou uma falha crítica no microfone durante a segunda gravação.
        A análise técnica encontrou pacotes incompletos no arquivo gerado pelo sistema.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertTrue(
            section(named: "Principais pontos abordados", in: summary)
                .contains("O teste de áudio confirmou uma falha crítica"),
            summary
        )
    }

    func testCustomSynthesisAndActionsHeadingsWorkWithEditorDefaults() async throws {
        let template = SummaryTemplate(
            id: "custom-editor-headings",
            displayName: "Retrospectiva",
            instructions: "Crie uma síntese fiel, registre decisões confirmadas e liste as ações assumidas.",
            sections: ["Síntese", "Decisões", "Ações"]
        )
        let transcript = """
        A conversa avaliou os resultados da primeira etapa do Projeto Aurora.
        A diretoria decidiu ampliar o piloto para Recife.
        Marina vai enviar o cronograma atualizado até sexta-feira.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: template
        )

        XCTAssertEqual(
            section(named: "Síntese", in: summary),
            "A conversa avaliou os resultados da primeira etapa do Projeto Aurora.",
            summary
        )
        XCTAssertTrue(section(named: "Decisões", in: summary).contains("decidiu ampliar"), summary)
        XCTAssertTrue(section(named: "Ações", in: summary).contains("Marina vai enviar"), summary)
    }

    func testProjectSyncKeepsTasksAndCollaborationActionsInTheirOwnSections() async throws {
        let transcript = """
        O módulo fiscal foi concluído e está em homologação.
        O risco atual é a dependência do certificado externo.
        Marina vai finalizar a documentação técnica até sexta-feira.
        Rafael vai revisar com o time de segurança a divisão de responsabilidades amanhã.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .projectSync
        )
        let tasks = section(named: "Próximas tarefas e marcos", in: summary)
        let collaboration = section(
            named: "Colaboração do time e itens de ação",
            in: summary
        )

        XCTAssertTrue(tasks.contains("Marina vai finalizar"), summary)
        XCTAssertFalse(tasks.contains("Rafael vai revisar"), summary)
        XCTAssertTrue(collaboration.contains("Rafael vai revisar"), summary)
    }

    func testCombinedNextStepsSectionKeepsActionWithoutLexicalSectionCue() async throws {
        let transcript = """
        O cronograma prevê a homologação do ambiente em 14 de setembro.
        João vai testar a integração amanhã.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .customerOnboarding
        )

        XCTAssertTrue(
            section(named: "Cronograma e próximos passos", in: summary)
                .contains("João vai testar a integração amanhã."),
            summary
        )
    }

    func testTroubleshootingPreservesProblemProcedureResultAndUnlistedActionVerb() async throws {
        let transcript = """
        O cliente relatou que o painel exibia uma tela branca após o login.
        O suporte limpou o cache do navegador.
        Depois disso o painel voltou a funcionar normalmente.
        Carla vai acompanhar o cliente amanhã.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .troubleshooting
        )
        let problem = section(named: "Desafio ou problema", in: summary)
        let solutions = section(named: "Soluções sugeridas e resultados", in: summary)
        let actions = section(named: "Próximos passos", in: summary)

        XCTAssertTrue(problem.contains("tela branca"), summary)
        XCTAssertFalse(problem.contains("limpou o cache"), summary)
        XCTAssertTrue(solutions.contains("limpou o cache"), summary)
        XCTAssertTrue(solutions.contains("voltou a funcionar"), summary)
        XCTAssertTrue(actions.contains("Carla vai acompanhar o cliente amanhã."), summary)
    }

    func testGroundedRendererRoutesActionAssignedBeforeNextSteps() throws {
        let transcript = """
        O objetivo da reunião é revisar o fechamento mensal.
        Marina vai enviar o relatório aprovado até sexta-feira.
        """

        let rerouted = try GroundedSummaryRenderer.render(
            selection: [[0], [1], [1]],
            transcript: transcript,
            template: .standardMeeting
        )
        XCTAssertFalse(
            section(named: "Principais pontos abordados", in: rerouted)
                .contains("Marina vai enviar")
        )
        XCTAssertTrue(
            section(named: "Próximos passos", in: rerouted)
                .contains("Marina vai enviar o relatório aprovado até sexta-feira.")
        )
        let valid = try GroundedSummaryRenderer.render(
            selection: [[0], [], [1]],
            transcript: transcript,
            template: .standardMeeting
        )
        XCTAssertTrue(
            section(named: "Próximos passos", in: valid)
                .contains("Marina vai enviar o relatório aprovado até sexta-feira."),
            valid
        )
    }

    func testGroundedRendererCompletesExplicitActionsWhenModelReturnsNone() throws {
        let transcript = """
        O objetivo da reunião é revisar o fechamento mensal.
        Marina vai enviar o relatório aprovado até sexta-feira.
        """

        let summary = try GroundedSummaryRenderer.render(
            selection: [[0], [], []],
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertTrue(
            section(named: "Próximos passos", in: summary)
                .contains("Marina vai enviar o relatório aprovado até sexta-feira."),
            summary
        )
    }

    func testGroundedRendererCapsAnOverlongLocalModelSelection() throws {
        let mainPoints = (1...20).map {
            "O tópico estratégico \($0) foi analisado com impacto operacional relevante."
        }
        let transcript = (["O objetivo da reunião é revisar o planejamento anual."] + mainPoints)
            .joined(separator: "\n")

        let summary = try GroundedSummaryRenderer.render(
            selection: [[0], Array(1...20), []],
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertEqual(
            section(named: "Principais pontos abordados", in: summary)
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix("- ") }
                .count,
            16
        )
    }

    func testGroundedRendererRejectsSwappedCustomSectionEvidence() throws {
        let template = SummaryTemplate(
            id: "business-review-renderer",
            displayName: "Revisão de negócio",
            instructions: "Em Financeiro, destaque receitas e margem. Em Pessoas, destaque contratações e retenção.",
            sections: ["Financeiro", "Pessoas"]
        )
        let transcript = """
        A receita recorrente cresceu 18% e a margem permaneceu acima da meta trimestral.
        A empresa contratou três engenheiros e manteve a retenção do time no período.
        """

        XCTAssertThrowsError(
            try GroundedSummaryRenderer.render(
                selection: [[1], [0]],
                transcript: transcript,
                template: template
            )
        )
        let summary = try GroundedSummaryRenderer.render(
            selection: [[0], [1]],
            transcript: transcript,
            template: template
        )
        XCTAssertTrue(section(named: "Financeiro", in: summary).contains("receita"), summary)
        XCTAssertTrue(section(named: "Pessoas", in: summary).contains("três engenheiros"), summary)
    }

    func testBuiltInCombinedSectionsCoverEveryPromisedConcept() async throws {
        let accountTranscript = """
        A conta utiliza o produto diariamente com 85 pessoas em três departamentos.
        O cliente declarou satisfação com a estabilidade, mas relatou frustração no cadastro.
        """
        let accountSummary = try await provider.generateSummary(
            transcript: accountTranscript,
            template: .accountManagement
        )
        let usageAndSatisfaction = section(named: "Uso atual e satisfação", in: accountSummary)
        XCTAssertTrue(usageAndSatisfaction.contains("85 pessoas"), accountSummary)
        XCTAssertTrue(usageAndSatisfaction.contains("satisfação"), accountSummary)

        let troubleshootingTranscript = """
        O cliente relatou falhas intermitentes ao acessar a rede corporativa.
        O suporte sugeriu reiniciar o roteador e o acesso voltou a funcionar normalmente.
        """
        let troubleshootingSummary = try await provider.generateSummary(
            transcript: troubleshootingTranscript,
            template: .troubleshooting
        )
        XCTAssertTrue(
            section(named: "Soluções sugeridas e resultados", in: troubleshootingSummary)
                .contains("reiniciar o roteador"),
            troubleshootingSummary
        )

        let performedSolutionTranscript = """
        O cliente relatou falhas intermitentes na rede corporativa.
        O suporte reiniciou o roteador e o acesso voltou a funcionar normalmente.
        """
        let performedSolutionSummary = try await provider.generateSummary(
            transcript: performedSolutionTranscript,
            template: .troubleshooting
        )
        XCTAssertTrue(
            section(named: "Soluções sugeridas e resultados", in: performedSolutionSummary)
                .contains("O suporte reiniciou o roteador"),
            performedSolutionSummary
        )
        XCTAssertFalse(
            section(named: "Desafio ou problema", in: performedSolutionSummary)
                .contains("O suporte reiniciou o roteador"),
            performedSolutionSummary
        )

        let onboardingTranscript = """
        O cronograma prevê homologação em 14 de setembro e início assistido na semana seguinte.
        Marina vai enviar a documentação final até sexta-feira.
        """
        let onboardingSummary = try await provider.generateSummary(
            transcript: onboardingTranscript,
            template: .customerOnboarding
        )
        let timelineAndActions = section(named: "Cronograma e próximos passos", in: onboardingSummary)
        XCTAssertTrue(timelineAndActions.contains("14 de setembro"), onboardingSummary)
        XCTAssertTrue(timelineAndActions.contains("Marina vai enviar"), onboardingSummary)

        let customerTranscript = """
        Há uma oportunidade de ampliar o uso para outras duas áreas da empresa.
        Rafael vai agendar a conversa comercial na próxima semana.
        """
        let customerSummary = try await provider.generateSummary(
            transcript: customerTranscript,
            template: .existingCustomer
        )
        let opportunities = section(named: "Oportunidades e próximos passos", in: customerSummary)
        XCTAssertTrue(opportunities.contains("oportunidade de ampliar"), customerSummary)
        XCTAssertTrue(opportunities.contains("Rafael vai agendar"), customerSummary)
    }

    func testHiringTemplateRejectsGenericResponsibilityAndPresentationTransitions() async throws {
        let transcript = """
        Então, essa responsabilidade também é compartilhada entre todas as instituições envolvidas.
        Vamos começar pela apresentação do contexto geral na próxima tela.
        Será que devemos apresentar agora os detalhes do documento?
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .hiring
        )

        XCTAssertEqual(
            section(named: "Competências e experiências", in: summary),
            "Não informado na transcrição",
            summary
        )
        XCTAssertEqual(
            section(named: "Disponibilidade e pretensão salarial", in: summary),
            "Não informado na transcrição",
            summary
        )
        XCTAssertEqual(
            section(named: "Próximos passos", in: summary),
            "Não informado na transcrição",
            summary
        )
        XCTAssertEqual(
            section(named: "Minhas observações", in: summary),
            "N/A",
            summary
        )
    }

    func testRealSummaryFixtureWhenProvided() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["QAPIA_SUMMARY_FIXTURE"] else {
            throw XCTSkip("Defina QAPIA_SUMMARY_FIXTURE para validar uma transcrição real.")
        }
        let transcript = try String(
            contentsOf: URL(fileURLWithPath: fixturePath),
            encoding: .utf8
        )

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )
        print("\n=== QAPIA SUMMARY QUALITY OUTPUT ===\n\(summary)\n=== END QAPIA SUMMARY QUALITY OUTPUT ===\n")

        let mainPoints = section(named: "Principais pontos abordados", in: summary)
        if transcript.split(whereSeparator: { $0.isWhitespace }).count > 400 {
            XCTAssertGreaterThanOrEqual(bullets(in: mainPoints).count, 7, summary)
        }
        XCTAssertFalse(
            mainPoints.localizedCaseInsensitiveContains("vamos começar"),
            "Transições de apresentação não devem ocupar espaço no resumo.\n\(summary)"
        )
        let normalizedTranscript = normalizeWhitespace(transcript)
        for bullet in summary.components(separatedBy: .newlines) where bullet.hasPrefix("- ") {
            XCTAssertTrue(
                normalizedTranscript.contains(normalizeWhitespace(String(bullet.dropFirst(2)))),
                "Todo tópico precisa ser comprovável como trecho integral da transcrição.\n\(bullet)"
            )
        }
    }

    func testGroundedSelectionRejectsMissingSectionsAndUnknownSentenceIDs() throws {
        XCTAssertThrowsError(
            try GroundedSentenceSelection.parse(
                "SEC0: S0\nSEC1: S99\nSEC2: NONE",
                sectionCount: 3,
                validSentenceIDs: [0, 1, 2]
            )
        )
        XCTAssertThrowsError(
            try GroundedSentenceSelection.parse(
                "SEC0: S0\nSEC1: S1",
                sectionCount: 3,
                validSentenceIDs: [0, 1, 2]
            )
        )
        XCTAssertEqual(
            try GroundedSentenceSelection.parse(
                "SEC0: S0\nSEC1: S1,S2\nSEC2: NONE",
                sectionCount: 3,
                validSentenceIDs: [0, 1, 2]
            ),
            [[0], [1, 2], []]
        )
    }

    func testSummaryValidatorRejectsEvenANumberlessInventedClaim() {
        let transcript = """
        O objetivo da reunião é revisar o Projeto Aurora.
        A equipe confirmou que a entrega permanece em análise.
        """
        let grounded = """
        ## Objetivo da reunião

        O objetivo da reunião é revisar o Projeto Aurora.

        ## Principais pontos abordados

        - A equipe confirmou que a entrega permanece em análise.

        ## Próximos passos

        Não informado na transcrição
        """
        let invented = grounded.replacingOccurrences(
            of: "A equipe confirmou que a entrega permanece em análise.",
            with: "A equipe aprovou definitivamente a entrega."
        )

        XCTAssertTrue(
            SummaryOutputValidator.isGrounded(
                grounded,
                in: transcript,
                template: .standardMeeting
            )
        )
        XCTAssertFalse(
            SummaryOutputValidator.isGrounded(
                invented,
                in: transcript,
                template: .standardMeeting
            )
        )
    }

    func testExecutiveSynthesisPromptUsesOnlyGroundedDraftAndExactTemplateSections() {
        let groundedDraft = """
        ## Resumo executivo

        A reunião avaliou a prontidão do Projeto Aurora.

        ## Decisões

        - A diretoria decidiu manter a homologação por mais uma semana.

        ## Ações

        - Marina vai enviar o relatório até sexta-feira.
        """
        let template = SummaryTemplate(
            id: "executive-test",
            displayName: "Ata executiva",
            instructions: "Sintetize contexto, decisões e ações sem inferências.",
            sections: ["Resumo executivo", "Decisões", "Ações"]
        )

        let prompt = ExecutiveSynthesisPrompt.user(
            groundedDraft: groundedDraft,
            template: template
        )

        XCTAssertTrue(ExecutiveSynthesisPrompt.system.contains("atas executivas"))
        XCTAssertTrue(ExecutiveSynthesisPrompt.system.contains("ação, responsável e prazo"))
        XCTAssertTrue(ExecutiveSynthesisPrompt.system.contains("Não acrescente conhecimento externo"))
        XCTAssertTrue(prompt.contains("## Resumo executivo\n## Decisões\n## Ações"))
        XCTAssertTrue(prompt.contains(template.instructions))
        XCTAssertTrue(prompt.contains("<evidencias>\n\(groundedDraft)\n</evidencias>"))
        XCTAssertFalse(prompt.contains("[S0]"))
    }

    func testSynthesizedSummaryValidatorAcceptsGroundedExecutiveRewrite() {
        let evidence = executiveEvidenceFixture()
        let summary = """
        ## Objetivo da reunião

        A reunião teve como foco avaliar a prontidão do Projeto Aurora para a liberação nacional.

        ## Principais pontos abordados

        - A telemetria registrou redução de 37% no tempo de processamento.
        - A diretoria decidiu manter a homologação por mais uma semana.

        ## Próximos passos

        - Marina enviará o relatório consolidado até sexta-feira.
        """

        XCTAssertTrue(
            SynthesizedSummaryValidator.isValid(
                summary,
                groundedEvidenceMarkdown: evidence,
                template: .standardMeeting
            ),
            summary
        )
    }

    func testSynthesizedSummaryValidatorRejectsInventedAnchorsAndTemplateDrift() {
        let evidence = executiveEvidenceFixture()
        let grounded = """
        ## Objetivo da reunião

        A reunião avaliou a prontidão do Projeto Aurora para a liberação nacional.

        ## Principais pontos abordados

        - A telemetria mostrou redução de 37% no tempo de processamento.
        - A diretoria decidiu manter a homologação por mais uma semana.

        ## Próximos passos

        - Marina vai enviar o relatório consolidado até sexta-feira.
        """

        let inventedNumber = grounded.replacingOccurrences(of: "37%", with: "52%")
        let inventedOwner = grounded.replacingOccurrences(of: "Marina", with: "Carlos")
        let inventedDeadline = grounded.replacingOccurrences(
            of: "sexta-feira",
            with: "segunda-feira"
        )
        let wrongHeading = grounded.replacingOccurrences(
            of: "## Principais pontos abordados",
            with: "## Conclusões executivas"
        )

        for invalid in [inventedNumber, inventedOwner, inventedDeadline, wrongHeading] {
            XCTAssertFalse(
                SynthesizedSummaryValidator.isValid(
                    invalid,
                    groundedEvidenceMarkdown: evidence,
                    template: .standardMeeting
                ),
                invalid
            )
        }
    }

    func testSynthesizedSummaryValidatorRequiresEveryActionOwnerAndDeadline() {
        let evidence = executiveEvidenceFixture()
        let missingDeadline = """
        ## Objetivo da reunião

        A reunião avaliou a prontidão do Projeto Aurora para a liberação nacional.

        ## Principais pontos abordados

        - A telemetria mostrou redução de 37% no tempo de processamento.
        - A diretoria decidiu manter a homologação por mais uma semana.

        ## Próximos passos

        - Marina vai enviar o relatório consolidado.
        """
        let missingAction = missingDeadline.replacingOccurrences(
            of: "- Marina vai enviar o relatório consolidado.",
            with: "Não informado na transcrição"
        )

        XCTAssertFalse(
            SynthesizedSummaryValidator.isValid(
                missingDeadline,
                groundedEvidenceMarkdown: evidence,
                template: .standardMeeting
            )
        )
        XCTAssertFalse(
            SynthesizedSummaryValidator.isValid(
                missingAction,
                groundedEvidenceMarkdown: evidence,
                template: .standardMeeting
            )
        )
    }

    func testSafeLocalValidatorStillRejectsInventedAnchorsAndUnrelatedActions() {
        let evidence = executiveEvidenceFixture()
        let valid = """
        ## Objetivo da reunião

        Avaliar a prontidão do Projeto Aurora para a liberação nacional.

        ## Principais pontos abordados

        - A telemetria reduziu em 37% o tempo de processamento.

        ## Próximos passos

        - Enviar o relatório consolidado — Responsável: Marina — Prazo: sexta-feira.
        """
        XCTAssertTrue(
            SynthesizedSummaryValidator.isSafelyGrounded(
                valid,
                groundedEvidenceMarkdown: evidence,
                template: .standardMeeting,
                sourceTranscript: evidence
            )
        )

        for invalid in [
            valid.replacingOccurrences(of: "37%", with: "81%"),
            valid.replacingOccurrences(of: "Marina", with: "Carlos"),
            valid.replacingOccurrences(
                of: "Enviar o relatório consolidado",
                with: "Contratar uma agência de publicidade"
            )
        ] {
            XCTAssertFalse(
                SynthesizedSummaryValidator.isSafelyGrounded(
                    invalid,
                    groundedEvidenceMarkdown: evidence,
                    template: .standardMeeting,
                    sourceTranscript: evidence
                ),
                invalid
            )
        }
    }

    func testIcebreakersAreExcludedWhileDecisionsAndCommitmentsRemain() async throws {
        let transcript = """
        Bom dia, tudo bem com vocês?
        Como foi o fim de semana?
        Foi ótimo, eu fui para a praia com a minha família.
        Você viu o jogo de ontem?
        O objetivo da reunião é revisar a prontidão do lançamento nacional.
        A telemetria confirmou estabilidade durante os testes de carga.
        A diretoria decidiu manter a homologação por mais uma semana.
        Marina vai enviar o relatório final até sexta-feira.
        """

        let summary = try await provider.generateSummary(
            transcript: transcript,
            template: .standardMeeting
        )

        XCTAssertFalse(summary.localizedCaseInsensitiveContains("fim de semana"), summary)
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("praia"), summary)
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("jogo de ontem"), summary)
        XCTAssertTrue(
            section(named: "Principais pontos abordados", in: summary)
                .contains("decidiu manter a homologação"),
            summary
        )
        XCTAssertTrue(
            section(named: "Próximos passos", in: summary)
                .contains("Marina vai enviar o relatório final até sexta-feira."),
            summary
        )
    }

    private func executiveEvidenceFixture() -> String {
        """
        ## Objetivo da reunião

        A reunião avaliou a prontidão do Projeto Aurora para a liberação nacional.

        ## Principais pontos abordados

        - A telemetria mostrou redução de 37% no tempo de processamento.
        - A diretoria decidiu manter a homologação por mais uma semana.

        ## Próximos passos

        - Marina vai enviar o relatório consolidado até sexta-feira.
        """
    }

    private func section(named heading: String, in summary: String) -> String {
        let marker = "## \(heading)"
        guard let markerRange = summary.range(of: marker) else {
            XCTFail("Seção ausente: \(heading).\n\(summary)")
            return ""
        }
        let remainder = summary[markerRange.upperBound...]
            .drop(while: { $0 == "\n" || $0 == "\r" })
        if let nextHeading = remainder.range(of: "\n\n## ") {
            return remainder[..<nextHeading.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bullets(in section: String) -> [String] {
        section.components(separatedBy: .newlines).filter { $0.hasPrefix("- ") }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let match = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = match.upperBound..<haystack.endIndex
        }
        return count
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func alphabeticToken(_ value: Int) -> String {
        var number = value
        var characters: [Character] = []
        repeat {
            let scalar = UnicodeScalar(97 + number % 26)!
            characters.append(Character(scalar))
            number /= 26
        } while number > 0
        return "bloco" + String(characters)
    }
}
