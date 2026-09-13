# QAP.ia — Technical Architecture

**Status:** Sprints 1 a 5 e Sprint 7 implementadas; pipeline local, persistência e nova camada visual integrados<br>
**Data:** 25/08/2026<br>
**Plataforma:** macOS 15+, Apple Silicon M1+

## 1. Objetivo arquitetural

Manter uma aplicação pequena, nativa e local-first, com separação suficiente para testar e evoluir o fluxo de gravação, transcrição e resumo sem criar uma arquitetura enterprise.

## 2. Stack aprovada

| Camada | Tecnologia | Responsabilidade |
|---|---|---|
| Aplicação | Swift + SwiftUI | UI nativa e ciclo de vida |
| Persistência | SwiftData | Meeting, segmentos e metadados |
| Áudio do sistema | Core Audio Process Tap | Captura somente o áudio reproduzido pelo Mac, sem acesso à tela |
| Microfone | AVFoundation | Captura do microfone |
| Transcrição | Whisper local | Transcrição pós-reunião, sem serviço externo |
| Resumo | Ollama local | Geração de Markdown com template |
| Clipboard | API nativa macOS | Cópia do resumo |

Não utilizar OpenAI API, Anthropic API ou outra API paga na V1.

## 3. Estrutura de módulos

```text
Qapia/
├── App/
├── Models/
├── App/
│   ├── Views/
│   └── Components/
├── ViewModels/
├── Services/
│   ├── Audio/
│   ├── Transcription/
│   ├── Summary/
│   └── Storage/
├── Resources/Templates/
└── Tests/
```

MVVM leve é suficiente. Cada serviço deve ter uma responsabilidade observável e testável.

## 4. Domínio mínimo

### Meeting

Campos mínimos:

```text
id
createdAt
finishedAt
recordedDuration
title
state
templateId
customTemplateStructure
transcript
summary
```

### RecordingSegment

Campos mínimos:

```text
id
meetingId
sequence
audioPath
duration
createdAt
```

`sequence` é a fonte de ordenação para transcrição e combinação do texto.

### MeetingState

```swift
enum MeetingState {
    case idle
    case recording
    case paused
    case preparingAudio
    case transcribing
    case summarizing
    case completed
    case failed
}
```

## 5. State machine e orquestração

`RecordingSession` coordena Start, Pause, Resume e Stop. `MeetingViewModel` coordena o estado visual e o pipeline pós-reunião. A View não chama Whisper ou Ollama diretamente.

```text
MeetingViewModel
    ├── RecordingSession
    │   └── AudioCaptureService
    └── postMeetingPipeline
        ├── MeetingFileStore
        ├── TranscriptionService
        │   └── WhisperService
        └── SummaryService
            └── SummaryProvider
                └── OllamaSummaryProvider
```

Regras obrigatórias:

- `recording → paused` encerra o segmento atual.
- `paused → recording` cria o próximo segmento.
- `recording → preparingAudio` e `paused → preparingAudio` são os únicos caminhos de finalização.
- `preparingAudio → transcribing → summarizing → completed` ocorre apenas após Stop.
- Qualquer etapa pode resultar em `failed`, sem apagar o áudio.

## 6. Captura de áudio

### AudioCaptureService

Responsável somente por:

- preparar permissões e dispositivos;
- iniciar um segmento;
- capturar áudio do sistema e microfone;
- encerrar o segmento;
- salvar o arquivo M4A/AAC e sua duração.

Não pode chamar Whisper, Ollama ou SwiftUI.

### RecordingSession

Responsável por:

- criar e manter a Meeting ativa;
- chamar o início e o encerramento de segmentos;
- manter a sequência dos segmentos;
- acumular o tempo efetivamente gravado;
- impedir gravação depois de Stop;
- encaminhar a Meeting para o pipeline pós-reunião.

A implementação deve preservar a separação temporal entre segmentos. Nenhum segmento é criado durante Pause.

## 7. Armazenamento de arquivos

```text
Application Support/
└── Qapia/
    └── Meetings/
        └── {meetingUUID}/
            ├── audio/
            │   ├── segment-001.m4a
            │   ├── segment-002.m4a
            │   └── segment-003.m4a
            ├── transcript.txt
            └── summary.md
```

`MeetingFileStore` cria diretórios, gera nomes seguros, grava e lê transcript/summary e verifica a existência dos segmentos. O formato padrão de armazenamento é M4A/AAC; WAV não é o armazenamento padrão.

## 8. Transcrição

### WhisperService

Responsável exclusivamente por transcrever um segmento:

```swift
func transcribe(
    segment: RecordingSegment
) async throws -> String
```

### TranscriptionService

Responsável por:

1. receber os segmentos da Meeting;
2. ordenar por `sequence`;
3. chamar Whisper para cada segmento;
4. preservar o texto correspondente a cada segmento enquanto processa;
5. combinar os textos na ordem correta;
6. persistir o transcript final.

Whisper não é iniciado em Pause e não há realtime, diarização, speaker identification, timestamps por sentença ou tradução automática na V1.

O runtime oficial `whisper.cpp` é empacotado dentro do `QAP.ia.app`. Quando ainda não houver um modelo válido no Mac, o QAP.ia baixa automaticamente o modelo multilíngue `Small`, confere seu SHA-1 e o guarda em `Application Support/Qapia/Whisper/ggml-small.bin`. A transcrição usa português fixo, timestamps internos para não perder trechos e decodificação greedy com cinco candidatos. Não usa prompt inicial, glossário nem substituição canônica; timestamps não são exibidos ao usuário. Não há dependência de Homebrew, FFmpeg ou comandos externos; somente o arquivo de modelo é obtido da internet e o áudio nunca é enviado.

## 9. Resumo

Abstração obrigatória:

```swift
protocol SummaryProvider {
    func generateSummary(
        transcript: String,
        template: SummaryTemplate
    ) async throws -> String
}
```

Implementação: `OnDeviceSummaryProvider`, apesar do nome histórico, usa exclusivamente o Ollama pela interface de loopback. `OllamaResourcePreparationCoordinator` verifica o runtime em toda abertura, instala a distribuição oficial assinada quando ausente, inicia o serviço e garante uma variante quantizada do Qwen 3.5 dimensionada pela memória unificada. A geração entrega a transcrição limpa diretamente ao modelo para uma síntese executiva, exige as seções exatas do template e valida estrutura, números, datas e nível de síntese sem impedir paráfrases legítimas. Uma primeira redação rejeitada recebe uma tentativa de reparo; se ela também falhar, o erro é exibido e a transcrição permanece preservada. O produto nunca entrega o fallback extrativo como se fosse uma ATA executiva.

O fallback normaliza as quebras de linha do Whisper, segmenta frases completas, descarta ruído conversacional, ranqueia relevância e cobertura e remove duplicatas. A quantidade de pontos cresce com o conteúdo da reunião. Cada fato renderizado é um trecho literal da transcrição; próximos passos exigem um compromisso explícito.

`SummaryService` resolve o template, chama o provider e persiste `summary.md`. Todo o processamento é local.

## 10. Persistência e recuperação

SwiftData guarda metadados e referências dos arquivos. O áudio é mantido no diretório da Meeting. Falhas no transcript ou summary não removem os segmentos.

Ao abrir o aplicativo, o histórico deve ser reconstruído a partir do SwiftData e os caminhos locais devem ser validados antes de exibir ações de revisão.

`SwiftDataMeetingStore` persiste Meeting e RecordingSegment a cada transição relevante do pipeline. Estados ativos encontrados após uma reinicialização são convertidos em falha recuperável, mantendo os artefatos finalizados. Paths ausentes são exibidos como indisponíveis e nunca provocam exclusão automática da Meeting, transcrição ou resumo.

## 11. Permissões e erros

Devem existir estados/erros compreensíveis para:

- microfone negado;
- captura de tela/áudio negada;
- dispositivo indisponível;
- falha ao iniciar ou encerrar segmento;
- falha ao salvar arquivo;
- Whisper indisponível ou falhando;
- Ollama não instalado, parado ou sem modelo;
- falha na geração do resumo.

O erro deve ser apresentado sem esconder a origem da gravação. A Meeting e os arquivos já existentes continuam recuperáveis.

## 12. Testabilidade

Priorizar protocolos e injeção de dependências nos serviços que dependem de hardware ou processos locais:

- fake de `AudioCaptureService` para testar segmentos;
- fake de `WhisperService` para testar ordenação e merge;
- fake de `SummaryProvider` para testar templates e persistência;
- `MeetingFileStore` direcionável para um diretório temporário em testes.

## 13. Segurança de escopo

Não adicionar backend, cloud sync, integrações com plataformas de reunião, analytics, telemetria, diarização biométrica, busca vetorial ou funcionalidades mobile. O Google Calendar é a única integração externa e recebe apenas metadados de agenda; áudio, transcrição e resumo permanecem locais.

## 14. Status de implementação

O app integra captura segmentada, transcrição com `whisper.cpp`, geração de ata exclusivamente com Ollama/Qwen local e histórico persistente em SwiftData. O pipeline percorre `preparingAudio → transcribing → summarizing → completed`, grava `transcript.txt` e `summary.md`, atualiza os metadados a cada transição e preserva os artefatos em falhas ou reinicializações. A troca de template inicia uma nova geração automaticamente e descarta resultados assíncronos obsoletos.

A camada visual `Signal Calm` usa tokens dinâmicos para claro/escuro, controles SwiftUI iconográficos e uma frequência alimentada por RMS normalizado dos buffers de áudio. Somente valores `Float` limitados chegam à MainActor; os buffers permanecem na fila de captura em tempo real.

## 15. Catálogo local de templates

`LocalSummaryTemplateStore` persiste o catálogo em `Application Support/Qapia/Templates/templates.json`. Os templates padrão mantêm IDs estáveis e podem ser editados, mas somente templates criados pelo usuário podem ser excluídos. Nome, instruções e seções são normalizados e validados antes de qualquer gravação em disco.

Ao iniciar uma reunião, `SummaryTemplate.snapshotValue` serializa instruções e seções no campo legado de estrutura da Meeting. A geração usa esse snapshot, portanto uma alteração posterior no catálogo não muda a configuração das reuniões já registradas. O prompt mantém as instruções de segurança globais acima das orientações personalizadas.

## 16. Google Calendar, metadados e busca

`GoogleCalendarService` usa `ASWebAuthenticationSession`, OAuth 2.0 com PKCE e um Client ID do tipo iOS vinculado ao Bundle ID `br.com.qapia.app`. O navegador do sistema conduz o consentimento e retorna pelo esquema registrado no bundle. O app solicita apenas identidade básica e leitura de eventos; access/refresh tokens são persistidos no Chaveiro. O Client ID e seu esquema invertido são injetados durante o build e nenhum Client Secret é necessário ou distribuído.

Eventos futuros são consultados no calendário primário, convertidos em `CalendarEvent` e usados para agendar notificações locais 10 minutos antes. Ao iniciar pelo cartão da agenda, a `Meeting` recebe título, convidados, horário e identificador do evento.

Participantes representam os convidados conhecidos da agenda e podem ser corrigidos manualmente. Não há identificação biométrica nem diarização por voz no MVP.

A busca é inteiramente local e normaliza caixa e acentos sobre título, participantes, datas local/ISO, transcrição e resumo. O SwiftData recebeu campos opcionais/aditivos para manter compatibilidade com o histórico existente.

## 17. Distribuição

`Scripts/package-standalone.sh` valida a assinatura e cria um DMG contendo `QAP.ia.app` e o atalho para Applications. Quando um perfil de notarização é informado, o script submete e grampeia o ticket. O bundle inclui `whisper.framework`; modelos continuam sendo preparados no primeiro uso.
