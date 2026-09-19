# QAP.ia — Protocolo privado de revisão de transcrição

**Data:** 19/09/2026  
**Estado:** interface disponível; 18 reuniões aguardando revisão humana

## Objetivo

Transformar as transcrições-professoras em rótulos confiáveis para avaliação e, após os demais gates, possível treino privado. A unidade de revisão é uma reunião completa. Nenhum item é liberado automaticamente.

## Segurança operacional

- A interface escuta somente em `127.0.0.1` no servidor IA.
- O acesso desta máquina ocorre por túnel SSH local e token aleatório.
- Áudio, transcrições, correções, token e fila ficam fora do Git.
- Diretórios privados usam permissão `0700`; arquivos privados usam `0600`.
- O navegador recebe cabeçalhos sem cache e uma política de conteúdo restrita à própria origem.
- O servidor não registra o conteúdo das reuniões em logs.

## Ordenação da fila

A fila combina três sinais, usados somente para ordenar o trabalho:

| Sinal | Peso |
| --- | ---: |
| Divergência de sequência entre professor e app | 55% |
| Divergência no número de palavras | 25% |
| Proporção de palavras com confiança abaixo de 0,5 | 20% |

Esses sinais não medem acurácia. As duas transcrições são automáticas e podem estar erradas. O áudio é a única fonte primária para correção.

A fila inicial contém:

| Prioridade | Reuniões |
| --- | ---: |
| Urgente | 0 |
| Alta | 1 |
| Média | 4 |
| Normal | 13 |

A fila original não foi liberada para revisão: a inspeção visual encontrou um loop de palavras em silêncio e o detector ampliado identificou 7 de 18 saídas afetadas. O baseline v1 foi reprovado. A fila acima usa exclusivamente a v2, que passou com zero saídas patológicas.

## Procedimento por reunião

1. Ouvir o áudio integralmente, incluindo início, fim e trechos de silêncio.
2. Editar a transcrição corrigida com base no áudio, nunca apenas por comparação textual.
3. Preservar o que foi falado; não resumir, completar ideias ou melhorar argumentos.
4. Conferir números, datas, horários, prazos, negações, nomes, termos técnicos e siglas.
5. Corrigir omissões, duplicações, palavras alucinadas e limites incorretos.
6. Marcar incertezas sem inventar conteúdo, usando `[inaudível HH:MM:SS]` ou `[termo incerto HH:MM:SS]`.
7. Preencher o revisor e concluir todo o checklist antes de aprovar.
8. Excluir o item quando o áudio estiver corrompido, incompleto ou sem autoridade de uso; registrar o motivo.

## Separação dos gates

`asrReviewStatus: approved` significa apenas que a transcrição foi conferida com o áudio. O item só fica apto para treino quando também possui `consentStatus: approved_for_private_training`.

Documentação pendente de consentimento ou autoridade não deve ser marcada como aprovada por conveniência. A aprovação precisa apontar para o registro jurídico ou operacional mantido pelo responsável pelo projeto.

## Registros produzidos

Cada revisão grava, de forma atômica:

- `annotation.json`: estados, revisor, horário, checklist e caminhos dos artefatos;
- `corrected.transcript.txt`: texto corrigido, quando existente;
- `review-events.jsonl`: trilha sem conteúdo textual das ações de salvar, aprovar ou excluir.

O servidor rejeita aprovação sem revisor, sem os cinco checks ou com uma correção vazia/curta. O estado global mostra separadamente quantas transcrições estão aprovadas e quantas estão realmente aptas para treino.

## Gate seguinte

Quando houver um primeiro lote humano aprovado:

1. executar auditoria de concordância e amostragem dupla;
2. agrupar por organização e participantes para evitar vazamento entre splits;
3. congelar validação e teste antes de qualquer adapter;
4. criar o ledger de evidências e as atas de referência;
5. comparar Whisper Small, Whisper Large v3 e candidatos menores no conjunto bloqueado.
