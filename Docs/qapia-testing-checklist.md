# QAP.ia — Testing Checklist

**Status:** validação automatizada de pré-reenvio concluída; validação manual do vídeo da App Review ainda pendente.
**Data:** 31/08/2026
**Legenda:** `[ ]` não verificado · `[x]` verificado · `[—]` fora da sprint atual

## 0. Pré-reenvio App Store Review

- [x] `swift test` executado em Mac físico Apple Silicon com macOS 26.5.2.
- [x] 43 testes executados: 42 aprovados, 1 fixture opcional de áudio real ignorada e 0 falhas.
- [x] Fluxo e informações solicitadas pela Guideline 2.1 documentados em `Docs/app-review-resubmission-2026-08-31.md`.
- [ ] Vídeo completo gravado em usuário limpo, iniciando antes da abertura do app.
- [ ] Vídeo anexado à resposta e às informações de revisão.
- [ ] App Review Notes coladas e revisadas no App Store Connect.
- [ ] Mesmo build 1.0 (2) reenviado após a correção de metadados.

## 1. Sprint 0 — QA visual e de especificação

### Frames

- [x] Existem cinco frames nomeados: Empty, Recording, Paused, Processing e Meeting Detail.
- [x] Cada frame usa a janela de referência de 900 × 600 px.
- [x] O conteúdo principal não redesenha a barra de título nativa do macOS.
- [x] Sidebar, área de conteúdo e hierarquia de navegação são consistentes nos cinco estados.
- [x] Os cinco frames usam os mesmos tokens de tipografia, espaçamento, cores e cantos.
- [x] Os estados ativos, pausados, processando e concluído são distinguíveis sem depender apenas de cor.

### Conteúdo e interação

- [x] Empty apresenta Nova gravação e a mensagem de processamento local.
- [x] Recording apresenta indicador de gravação, contador, Pausar e Encerrar gravação.
- [x] Paused apresenta Pausado, contador, Retomar gravação e Encerrar gravação.
- [x] Processing apresenta etapas de áudio local, transcrição e resumo.
- [x] Meeting Detail apresenta título, template, abas Resumo/Transcrição e Copiar resumo.
- [x] O feedback de cópia é discreto e aparece como Copiado.
- [ ] O conteúdo de histórico mostra horário, título e duração.
- [ ] Os grupos do histórico são Hoje, Ontem, Esta semana e Anteriores.

### Acessibilidade e macOS feel

- [x] Contraste de texto e controles é suficiente para leitura normal e secundária na revisão visual.
- [x] Cada controle possui rótulo textual, não apenas ícone.
- [x] Os estados não dependem exclusivamente da cor.
- [ ] Foco de teclado e ordem de navegação podem ser definidos sem alterar o layout.
- [ ] O layout permanece legível com texto de resumo maior.
- [x] Não há aparência de dashboard SaaS ou página web.
- [x] Não há elementos visuais relacionados explicitamente a radioamadorismo.

## 2. Sprint 1 — SwiftUI Shell

- [x] Projeto compila em macOS 15+ Apple Silicon.
- [x] `NavigationSplitView` está definido para exibir sidebar e conteúdo.
- [x] Os cinco estados estão definidos e podem ser visualizados com dados mockados.
- [x] A navegação do histórico está ligada ao `MeetingViewModel`.
- [x] O mecanismo temporário de alternância de estados está disponível na toolbar.
- [x] Copy mock escreve o resumo no clipboard via protocolo injetável.
- [x] Nenhum serviço real de áudio, Whisper ou Ollama foi acoplado.

O ambiente atual possui Swift/Xcode. A suíte automatizada foi executada em 31/08/2026; a validação manual do fluxo gravado para a App Review permanece no gate de reenvio acima.

## 3. Sprint 2 — Audio Capture

- [x] Permissão de microfone é solicitada.
- [x] Permissão de captura de áudio/sistema é solicitada.
- [x] Start cria segment-001.
- [ ] Pause encerra o segmento atual.
- [x] Pause não inicia Whisper ou Ollama.
- [ ] Resume cria o próximo segmento.
- [ ] Uma sessão com múltiplos Pause/Resume gera segmentos M4A válidos.
- [ ] Nenhum áudio é capturado durante Pause.
- [ ] O contador soma apenas o tempo gravado.
- [x] Stop funciona a partir de Recording e Paused.
- [ ] Os segmentos podem ser reproduzidos e estão na ordem correta.
- [ ] Falha ao salvar não remove segmentos já gravados.

## 4. Sprint 3 — Whisper

- [x] Whisper só é iniciado após Stop.
- [x] Segmentos são ordenados por `sequence`.
- [x] Cada segmento é transcrito individualmente.
- [x] O transcript final preserva a ordem dos segmentos.
- [x] Transcript é persistido localmente.
- [x] Falha em um segmento não apaga os demais áudios.
- [x] Estado visual passa por Preparing Audio e Transcribing.

## 5. Sprint 4 — Ollama + templates

- [x] `SummaryProvider` é usado pela camada de serviço.
- [x] Ollama é chamado somente localmente.
- [x] Modelo indisponível gera erro compreensível.
- [x] Cada template gera a estrutura esperada.
- [x] O prompt impede invenção de nomes, fatos, decisões, responsáveis e prazos.
- [x] A saída é Markdown e é persistida como `summary.md`.
- [x] Falha no resumo preserva transcript e áudio.

## 6. Sprint 5 — Persistência

- [x] Meeting persiste no SwiftData.
- [x] RecordingSegment persiste no SwiftData.
- [x] Paths, durations, template, state, transcript e summary persistem.
- [x] Teste automatizado confirma o histórico após reabrir o armazenamento.
- [x] Histórico permanece disponível após reinício manual do QAP.ia.
- [x] Segmentos órfãos ou paths inválidos são sinalizados sem apagar dados.

## 7. Sprint 6 — Hardening

- [ ] Fluxo Start → Pause → Resume → Pause → Resume → Stop funciona ponta a ponta.
- [ ] Reunião longa funciona sem perda de segmentos.
- [ ] Muitos segmentos permanecem ordenados.
- [ ] Microfone desconectado é tratado.
- [ ] Ollama parado é tratado.
- [ ] Modelo Ollama ausente é tratado.
- [ ] Falha Whisper é tratada.
- [ ] Encerramento inesperado não apaga áudio já finalizado.
- [ ] Reinicialização do app preserva histórico e arquivos.
- [ ] Copy coloca o resumo integral no clipboard.

## 8. Gate final do MVP

- [ ] Uma reunião com pausa de cinco minutos gera somente o áudio efetivamente gravado.
- [ ] O transcript final é exibido.
- [ ] O template escolhido é aplicado.
- [ ] O summary é exibido e salvo em Markdown.
- [ ] Copiar resumo funciona.
- [ ] Nenhum conteúdo é enviado automaticamente a serviço externo.

## 9. Sprint 7 — Layout e identidade visual

- [x] Referências oficiais de Linear, Things e Raycast foram analisadas.
- [x] Sistema visual `Signal Calm` foi aplicado com tokens semânticos.
- [x] Controles genéricos foram substituídos por ações modernas e iconográficas.
- [x] Frequência recebe nível real do áudio do sistema e do microfone.
- [x] Interface respeita modo claro, modo escuro e Reduzir Movimento.
- [x] Alternância manual entre temas permanece após reiniciar o aplicativo.
- [x] Contador avança pelo relógio da sessão sem depender das atualizações da frequência.
- [x] Fluxo completo foi validado visualmente no app bundle.
- [x] Frequência viva foi confirmada com áudio real.

## 10. Sprint 8 — Gestão de templates

- [x] Configurações lista templates existentes.
- [x] Usuário cria e edita templates.
- [x] Usuário duplica e exclui templates criados por ele.
- [x] Templates padrão podem ser personalizados sem alterar reuniões concluídas.
- [x] Campos inválidos não são salvos.

## 11. Sprint 9 — Fechamento do MVP

- [x] Janela de sugestão começa 10 minutos antes do evento.
- [x] Gravação iniciada pelo evento herda título, horário e convidados.
- [x] Nome e participantes podem ser alterados e persistidos.
- [x] Busca encontra título, participante e conteúdo sem diferenciar maiúsculas ou acentos.
- [x] Busca indexa datas em formatos local e ISO.
- [x] Tokens OAuth são armazenados no Chaveiro.
- [x] O acesso ao calendário é somente leitura.
- [x] DMG de homologação pode ser criado pelo script standalone.
- [ ] Login real validado com OAuth Client ID do produto.
- [ ] Notificação real validada 10 minutos antes.
- [ ] DMG final assinado com Developer ID e notarizado.
