# QAP.ia — Sprint Backlog

**Data de referência:** 26/08/2026
**Sprint ativa:** Sprint 9 — Agenda, metadados, busca e distribuição
**Status geral:** Sprints 0 a 5, 7 e 8 concluídas. Sprint 9 implementada tecnicamente; conexão real aguarda Client ID e validação do responsável.

## 1. Regras de execução

- Uma sprint por vez.
- Não iniciar SwiftUI antes da aprovação visual da Sprint 0.
- Cada alteração deve ser pequena, verificável e restrita ao escopo aprovado.
- Não implementar funcionalidades fora do caminho Start → Pause/Resume → Stop → Whisper → Template → Ollama → Summary → Copy.

## 2. Sprint 0 — UX/UI

### Objetivo

Definir os cinco estados visuais essenciais do Qapia e produzir uma especificação suficientemente precisa para criação no Figma e posterior implementação em SwiftUI.

### Backlog

| ID | Item | Status | Critério de aceite |
|---|---|---|---|
| S0-01 | Consolidar produto, fluxo, escopo e restrições | Concluído | Definições registradas nos documentos operacionais |
| S0-02 | Definir linguagem visual nativa macOS | Concluído | Tokens, tipografia, espaçamento, cores e componentes descritos |
| S0-03 | Especificar Empty State | Concluído | Layout, conteúdo, ações e estados definidos |
| S0-04 | Especificar Recording State | Concluído | Status, contador, Pause e Finalizar definidos |
| S0-05 | Especificar Paused State | Concluído | Retomar, Finalizar e congelamento do contador definidos |
| S0-06 | Especificar Processing State | Concluído | Etapas de áudio, transcrição e resumo definidas |
| S0-07 | Especificar Meeting Detail | Concluído | Tabs, template, conteúdo e Copy definidos |
| S0-08 | Organizar frames e componentes no Figma | Concluído | Arquivo criado no plano Projetos com tokens, componentes e cinco frames de 900 × 600 px |
| S0-09 | Revisar e aprovar visual | Concluído | Aprovação dos cinco estados pelo responsável do produto |

### Entregável desta execução

`qapia-sprint-0-ux-ui-spec.md` contém a especificação e o handoff do arquivo Figma `Qapia — Sprint 0 — UX UI` ([abrir no Figma](https://www.figma.com/design/6gtxk32ZmLR3Pz296Id74G)), com tokens, componentes e cinco frames.

### Definition of Done

Sprint 0 foi concluída porque:

1. os cinco frames existirem no Figma;
2. os componentes e estados principais estiverem definidos;
3. a especificação permitir implementação sem decisões visuais fundamentais pendentes;
4. o responsável do produto aprovou o resultado;
5. nenhum código funcional tiver sido iniciado antes dessa aprovação.

## 3. Sprint 1 — SwiftUI Shell

**Status:** Concluída e aprovada.

Implementar NavigationSplitView, sidebar, histórico mockado, os cinco estados, TemplatePicker, Copy mock funcional e mecanismo temporário de troca de estados. Não implementar áudio, Whisper ou Ollama.

Entregue no workspace em `Qapia/`: pacote SwiftPM macOS 15+, modelos e store mock, `MeetingViewModel`, componentes SwiftUI, cinco telas de estado, clipboard e testes unitários. O ambiente desta execução não possui Swift/Xcode para confirmar o build.

## 4. Sprint 2 — Audio Capture

**Status:** Concluída e aprovada. Captura iniciada e encerrada manualmente com permissões de microfone e de Screen & System Audio Recording; segmento M4A gravado localmente.

Implementar segmentos M4A/AAC, captura de áudio do sistema e microfone, Start/Pause/Resume/Stop e permissões. Validar em navegador, Google Meet, Zoom e Teams. Não integrar Whisper.

## 5. Sprint 3 — Whisper

**Status:** Concluída e aprovada.

Transcrever segmentos somente após Stop, ordenar por sequência, combinar textos e persistir transcript. O runtime do Whisper acompanha o app; o modelo `small` é baixado e validado automaticamente no primeiro uso, sem Homebrew ou FFmpeg.

## 6. Sprint 4 — Ollama + Templates

**Status:** Concluída e aprovada.

Implementados `SummaryProvider`, `OllamaSummaryProvider`, cinco templates, template personalizado, geração via `qwen3.5:4b`, persistência de `summary.md`, nova tentativa e preservação de áudio/transcript em falhas.

## 7. Sprint 5 — Persistência

**Status:** Concluída e aprovada.

SwiftData consolidado para Meeting, RecordingSegment, durations, paths, transcript, summary, template e state. O histórico é reconstruído após reinício, processamentos interrompidos são recuperados como falha e caminhos de áudio indisponíveis são sinalizados sem apagar os demais dados.

## 8. Sprint 6 — Hardening

**Status:** Liberada, não iniciada; retomada após a validação visual da Sprint 7.

Testar fluxo completo, reuniões longas, muitos segmentos, permissões negadas, dispositivos desconectados, Ollama offline, modelo ausente, falha Whisper, encerramento inesperado e reinicialização.

## 9. Sprint 7 — Layout e identidade visual

**Status:** Concluída e aprovada.

Redesenhar layout, navegação e identidade visual para elevar hierarquia, legibilidade, consistência e experiência de uso. A direção `Signal Calm` usa neutros frios, azul-violeta como ação, ciano no sinal vivo e coral apenas para captura/erro. Inclui controles iconográficos, modos claro/escuro e frequência alimentada pelo nível real do áudio.

## 10. Sprint 8 — Gestão de templates

**Status:** Implementada e em validação.

Criada em Configurações uma interface para listar, criar, editar, duplicar e excluir templates de resumo. O catálogo é persistido localmente em JSON, templates padrão podem ser personalizados mas não excluídos, campos são validados antes de salvar e cada nova reunião guarda um snapshot das instruções e seções utilizadas.

## 11. Sprint 9 — Fechamento do MVP

**Status:** Implementada tecnicamente; integração externa pendente de credencial e homologação.

- Login OAuth 2.0 com PKCE, sessão protegida do macOS, navegador do sistema e tokens no Chaveiro.
- Consulta somente leitura dos próximos eventos.
- Lembrete local e sugestão de gravação 10 minutos antes.
- Título, horário e convidados herdados do evento.
- Nome e participantes editáveis.
- Busca por título, participante, data/hora, transcrição e resumo.
- Script de geração de DMG com suporte a Developer ID e notarização.

## 12. Próximo passo permitido

Fornecer um OAuth Client ID do tipo iOS para o Bundle ID `br.com.qapia.app`, homologar uma reunião real da agenda e então gerar o DMG final assinado/notarizado.
