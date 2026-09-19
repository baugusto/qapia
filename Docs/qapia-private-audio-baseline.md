# QAP.ia — Baseline das gravações privadas

**Data:** 19/09/2026

**Status:** amostra local preparada; transferência e treino bloqueados até autorização explícita e revisão humana

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

O servidor IA tem um ambiente Python isolado com `faster-whisper 1.2.1`. O Whisper Large v3 foi baixado e carregado com sucesso na RTX 3080 em FP16. O diretório privado de origem e o diretório de saídas foram criados com acesso restrito, mas nenhum áudio, transcript ou resumo foi transferido.

## Artefatos

- `AI/notebooks/recorded-audio-inventory.ipynb`: auditoria executada e reproduzível;
- `AI/scripts/profile_recorded_audio.py`: perfil sem exportar conteúdo;
- `AI/scripts/stage_private_sample.py`: staging anonimizado e privado;
- `AI/scripts/teacher_transcribe.py`: transcrição-professora na GPU;
- `AI/schemas/private-meeting-annotation.schema.json`: estados de consentimento e revisão.
