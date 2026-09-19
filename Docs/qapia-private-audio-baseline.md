# QAP.ia — Baseline das gravações privadas

**Data:** 19/09/2026

**Status:** fila e interface privadas prontas; treino bloqueado até documentação de consentimento/autoridade e revisão humana

## Escopo e privacidade

O inventário usa uma reunião ativa no SwiftData como unidade de análise. Títulos e participantes não são consultados. Os relatórios versionados contêm somente contagens, durações, estados e flags de integridade. Conteúdo, caminhos originais e a relação com identificadores do app permanecem em `AI/data/`, que é ignorado pelo Git e protegido com permissões restritas.

## Inventário observado

| Medida | Resultado |
| --- | ---: |
| Reuniões ativas no banco | 68 |
| Estado concluído | 58 |
| Estado falhou | 10 |
| Arquivos de áudio referenciados | 68 |
| Arquivos referenciados decodificáveis | 68 |
| Duração total referenciada | 19,65 horas |
| Pastas de reunião no filesystem | 400 |
| Pastas sem reunião ativa correspondente | 332 |
| Pastas órfãs com áudio | 9 |
| Grupos de áudio duplicado por SHA-256 | 0 |

As 332 pastas órfãs não entram na amostra. Elas podem refletir testes, reuniões removidas ou estados antigos do produto e não serão apagadas automaticamente.

## Seleção da amostra

Uma reunião entra no pool somente quando:

- está concluída no banco;
- possui áudio final M4A referenciado, existente e decodificável;
- tem pelo menos cinco minutos;
- a duração do arquivo é compatível com a duração registrada;
- possui transcrição e ata mínimas;
- arquivo e banco concordam sobre transcrição e ata;
- a densidade de palavras é plausível;
- não duplica conteúdo de áudio de outra reunião.

Trinta reuniões passaram a triagem. A seleção determinística escolheu 18 reuniões, totalizando 9,98 horas:

| Faixa | Reuniões |
| --- | ---: |
| 5–20 minutos | 5 |
| 20–45 minutos | 8 |
| 45 minutos ou mais | 5 |

Principais motivos de exclusão, que podem coexistir na mesma reunião:

| Motivo | Ocorrências |
| --- | ---: |
| Áudio menor que cinco minutos | 32 |
| Transcrição curta | 31 |
| Ata curta | 22 |
| Densidade textual implausível | 13 |
| Reunião não concluída | 10 |
| Sem áudio referenciado | 7 |

## Uso correto da amostra

A amostra é um **pool de anotação**, não um corpus pronto. A transcrição e a ata atuais foram geradas pelo sistema que está sendo substituído e, portanto, são rótulos ruidosos.

O fluxo aprovado é:

1. documentar consentimento e autoridade de uso para cada reunião;
2. gerar uma transcrição-professora com Whisper Large v3 e timestamps por palavra;
3. corrigir a transcrição com revisão humana;
4. produzir ledger de evidências e ata de referência revisados;
5. agrupar por organização e participantes;
6. só então definir treino, validação e teste sem vazamento.

## Infraestrutura preparada

O servidor IA tem um ambiente Python isolado com `faster-whisper 1.2.1`, CUDA 12 e cuDNN. O Whisper Large v3 foi executado na RTX 3080 em FP16. O diretório privado de origem usa permissão `0700`; manifestos, rótulos e arquivos de conteúdo usam `0600`.

Em 19/09/2026, após autorização explícita do responsável pelo projeto, o pacote privado foi transferido somente pela rede local para o diretório restrito do experimento. A verificação de entrada confirmou 55 de 55 arquivos presentes, com tamanho e SHA-256 corretos. O pacote não foi publicado, enviado a serviços externos ou incluído no Git.

## Resultado da transcrição-professora

O primeiro baseline do Whisper Large v3 concluiu as 18 reuniões, mas a inspeção visual do caso de maior risco revelou repetição patológica em silêncio. A auditoria foi ampliada com diversidade lexical, trigramas dominantes, compressibilidade textual e duplicação de segmentos. O gate retroativo reprovou 7 das 18 saídas da v1.

Nenhuma saída foi apagada ou sobrescrita. A v1 permanece isolada como evidência de falha. As 18 reuniões foram reprocessadas em uma pasta v2 independente com:

- Silero VAD antes da decodificação;
- reset de contexto entre janelas;
- fallback de temperatura de 0,0 a 1,0;
- limites de compressão, log-probability e ausência de fala;
- limiar de alucinação em silêncio de 2 segundos;
- timestamps por palavra preservados.

A v2 concluiu as 9,98 horas em 2.345,66 segundos, aproximadamente 15,32 vezes mais rápida que tempo real.

| Medida | v1 reprovada | v2 aceita para revisão |
| --- | ---: | ---: |
| Saídas esperadas/concluídas | 18/18 | 18/18 |
| Erros estruturais | 0 | 0 |
| Saídas com repetição patológica | 7 | 0 |
| Segmentos com timestamps | 14.974 | 10.915 |
| Palavras com timestamps | 74.175 | 87.077 |
| Rascunhos vazios | 0 | 0 |
| Probabilidade média por palavra | 0,9117 | 0,9281 |
| Palavras com probabilidade abaixo de 0,5 | 4.821 (6,50%) | 3.673 (4,22%) |
| Similaridade média com a saída atual | 0,4923 | 0,7919 |
| Similaridade mediana com a saída atual | 0,5160 | 0,8192 |

A razão média entre palavras do professor v2 e do app foi 1,0255, com amplitude de 0,4367 a 1,9445. Esses números **não medem acurácia**, porque nenhuma das duas saídas é referência humana. Eles apenas revelam divergência suficiente para priorizar a revisão dos casos extremos.

Todas as 18 saídas permanecem marcadas como `pending_human_correction`. A autorização de transferência e processamento não substitui a documentação de consentimento/autoridade de uso de cada reunião. Portanto, os dados ainda não podem alimentar treino, validação ou teste.

## Próximo gate

A fila privada foi reconstruída exclusivamente com a v2 aceita. Ela contém 1 item de alta prioridade, 4 médios e 13 normais, sem rascunho patológico. A interface local protegida permite ouvir os 19 arquivos, corrigir o professor, consultar a saída atual como referência ruidosa, preencher o checklist e aprovar ou excluir cada item. O protocolo completo está em `Docs/qapia-private-annotation-guide.md`.

O trabalho humano agora é:

1. revisar áudio, transcrição-professora e transcrição atual sem assumir que qualquer saída automática esteja correta;
2. corrigir texto, números, nomes, siglas, negações e omissões;
3. aprovar ou excluir cada reunião e registrar consentimento/autoridade;
4. somente depois produzir o ledger de evidências e a ata de referência.

## Artefatos

- `AI/notebooks/recorded-audio-inventory.ipynb`: auditoria executada e reproduzível;
- `AI/scripts/profile_recorded_audio.py`: perfil sem exportar conteúdo;
- `AI/scripts/stage_private_sample.py`: staging anonimizado e privado;
- `AI/scripts/teacher_transcribe.py`: transcrição-professora na GPU;
- `AI/scripts/audit_teacher_transcripts.py`: auditoria agregada sem conteúdo textual;
- `AI/scripts/prepare_annotation_queue.py`: fila privada orientada por risco de revisão;
- `AI/scripts/annotation_server.py`: interface localhost com áudio, correção e gates;
- `AI/schemas/private-meeting-annotation.schema.json`: estados de consentimento e revisão.
