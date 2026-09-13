# QAP.ia — Decision Log

**Data de referência:** 26/08/2026
**Regra:** decisões aprovadas não devem ser reabertas sem solicitação explícita.

## Decisões aprovadas

| ID | Decisão | Motivo / consequência | Status |
|---|---|---|---|
| D-001 | O nome exibido do produto é QAP.ia e o domínio é qapia.com.br | A grafia facilita a identificação de QAP e IA; identificadores internos permanecem estáveis | Aprovada e atualizada |
| D-002 | QAP significa “na escuta” e será uma referência sutil da marca | A origem reforça escuta e registro sem transformar o visual em radioamadorismo | Aprovada |
| D-003 | A V1 será exclusivamente macOS 15+ em Apple Silicon M1+ | Reduz superfície técnica e permite experiência nativa | Aprovada |
| D-004 | A aplicação será Swift + SwiftUI | Stack nativa obrigatória para a V1 | Aprovada |
| D-005 | A persistência será local com SwiftData | Histórico local sem backend ou cloud sync | Aprovada |
| D-006 | A captura usará ScreenCaptureKit + AVFoundation | Cobre áudio do sistema e microfone | Aprovada |
| D-007 | Whisper será executado localmente e somente após Stop | Privacidade e previsibilidade; Pause nunca dispara transcrição | Aprovada |
| D-008 | Ollama local será o provider inicial de resumo | Evita API externa paga e mantém conteúdo local | Aprovada |
| D-009 | O resumo será abstraído por `SummaryProvider` | Permite providers futuros sem acoplamento da UI | Aprovada |
| D-010 | A gravação será segmentada em M4A/AAC | Pause encerra o segmento; Resume cria o próximo; pausas não entram no áudio | Aprovada |
| D-011 | A V1 não concatena fisicamente os segmentos | Transcrição individual preserva ordenação e simplifica o pipeline inicial | Aprovada |
| D-012 | A interface terá cinco estados principais: Empty, Recording, Paused, Processing e Meeting Detail | Mantém a V1 simples e cobre o fluxo principal | Aprovada |
| D-013 | Figma é a fonte de verdade visual antes do SwiftUI | Evita decisões visuais fundamentais durante a implementação | Aprovada |
| D-014 | A linguagem visual será nativa macOS, com SF Pro, espaço negativo e poucos borders | Prioriza clareza e baixa densidade visual | Aprovada |
| D-015 | Desenvolvimento será feito prioritariamente com Codex/vibe coding | Define o modo de execução do projeto | Aprovada |
| D-016 | Não haverá backend, login, telemetria, analytics ou sincronização na V1 | Preserva o princípio local-first e o foco do MVP | Aprovada |
| D-017 | A implementação não avança automaticamente de sprint | Cada etapa precisa ser revisada e aprovada | Aprovada |
| D-018 | O modelo padrão de resumo local é `qwen3.5:4b` | Já disponível no ambiente validado, porte compatível com uso local e cobertura multilíngue | Aprovada na implementação da Sprint 4 |
| D-019 | A Sprint 7 será dedicada à reformulação de UX e identidade visual | O layout precisa ganhar hierarquia, consistência, qualidade visual e resposta viva ao áudio antes da distribuição | Concluída e aprovada |
| D-020 | A Sprint 8 adicionará gestão de templates em Configurações | Usuário poderá modificar os modelos atuais e criar novas estruturas de resumo | Implementada e em validação |
| D-021 | A identidade visual da Sprint 7 será `Signal Calm` | Neutros mantêm foco; azul-violeta e ciano representam inteligência e sinal; coral fica reservado para captura e erro | Aprovada na implementação |
| D-022 | Templates serão persistidos em JSON local e reuniões guardarão um snapshot do template usado | Evita migração do histórico SwiftData e impede que edições futuras alterem a estrutura de reuniões anteriores | Implementada na Sprint 8 |
| D-023 | Google Calendar usará OAuth 2.0 com PKCE pela sessão protegida do macOS, Client ID do tipo iOS e escopo somente leitura | O app nunca recebe senha nem embute Client Secret; tokens ficam no Chaveiro | Implementada; aguarda Client ID iOS |
| D-024 | Participantes iniciais vêm dos convidados do calendário e podem ser corrigidos manualmente | Diarização por voz não é suficientemente confiável nem necessária para fechar o MVP | Implementada |
| D-025 | A busca local indexa metadados, data/hora, transcrição e resumo sem backend | Preserva a arquitetura local-first | Implementada |
| D-026 | O instalador será DMG, com Developer ID e notarização para distribuição pública | Permite instalação sem Xcode e atende ao Gatekeeper | Script implementado; credenciais Apple pendentes |

## Registro operacional desta execução

### O-001 — Sprint 0 executada no Figma

A integração Figma foi conectada ao plano `Projetos` e a Sprint 0 foi executada no arquivo [Qapia — Sprint 0 — UX UI](https://www.figma.com/design/6gtxk32ZmLR3Pz296Id74G). O arquivo contém a estrutura de páginas, tokens Light, estilos SF Pro, quatro componentes reutilizáveis e os cinco frames de alta fidelidade.

Isso mantém D-013 como fonte de verdade visual. A aprovação visual dos cinco estados foi registrada antes do início da Sprint 1.

### O-002 — Aprovação visual da Sprint 0

O responsável do produto aprovou o visual dos cinco estados no arquivo Figma. A decisão libera a implementação do shell SwiftUI, mantendo tokens, hierarquia, conteúdo e dimensões como referência.

### O-003 — Shell SwiftUI da Sprint 1

Foi criado um pacote SwiftPM macOS 15+ em `Qapia/` com `NavigationSplitView`, sidebar, histórico mockado, cinco estados, `TemplatePicker`, clipboard mock e alternância temporária de estados. Áudio real, Whisper, Ollama e SwiftData permanecem fora do escopo. O build ainda precisa ser executado em Xcode.

### O-004 — Pipeline local até o resumo

As Sprints 2 a 4 integraram captura M4A segmentada, transcrição automática com `whisper.cpp` e resumo Markdown com Ollama local. A comunicação do resumo é restrita ao loopback, usa `qwen3.5:4b` e mantém áudio e transcript recuperáveis em caso de falha.

### O-005 — Histórico persistente

A Sprint 5 substituiu o histórico temporário por SwiftData. Meeting, segmentos, paths, durações, template, estado, transcrição e resumo são salvos localmente. O aplicativo recupera processamentos interrompidos como falha, preserva arquivos já finalizados e sinaliza paths ausentes sem excluir dados.

## Pontos a decidir antes das sprints técnicas

Estes pontos não bloqueiam a aprovação visual, mas devem ser tratados na sprint correspondente:

- comportamento detalhado de seleção de dispositivos de entrada;
- tratamento de recuperação após encerramento inesperado.

Nenhum desses pontos deve ser resolvido adicionando funcionalidade na Sprint 0.
