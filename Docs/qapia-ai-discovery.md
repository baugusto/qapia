# QAP.ia — Descoberta de IA local e plano de especialização

**Status:** aprovado para descoberta; treino e integração ainda bloqueados por gates de dados e qualidade

**Data da revisão:** 18/09/2026

**Branch de trabalho:** `research/qapia-slm`
**Princípio:** qualidade e fidelidade factual têm precedência sobre tamanho e velocidade

## 1. Decisão executiva

O QAP.ia não deve treinar um modelo de linguagem do zero. A rota com melhor relação entre qualidade, risco e custo é:

1. manter **dois subsistemas especializados** — reconhecimento de fala e inteligência de reunião;
2. selecionar uma base textual densa de **3–4 bilhões de parâmetros**, permissiva para uso comercial;
3. especializá-la com QLoRA em tarefas de extração factual e redação de atas;
4. processar reuniões longas de forma hierárquica, sem truncar a conversa;
5. embutir uma versão quantizada somente depois de ela superar o baseline atual em um conjunto PT-BR reservado e revisado por humanos.

Um SLM textual não substitui o Whisper. A melhoria de transcrição exige uma trilha própria de ASR, com dados de áudio PT-BR e métricas de palavras, números e entidades. A ata deve consumir uma transcrição estruturada com timestamps e, quando disponível, falantes.

## 2. Arquitetura alvo

```text
Áudio local
  └─ ASR PT-BR especializado
       ├─ segmentos + timestamps
       ├─ confiança por trecho
       └─ vocabulário/contexto da reunião
            ↓
Normalização segura
  └─ preserva números, datas, nomes e negações
            ↓
SLM — extração por janelas sobrepostas
  └─ ledger de evidências
       ├─ tópicos
       ├─ fatos + trechos-fonte
       ├─ decisões
       ├─ ações + responsável/prazo somente quando explícitos
       ├─ pendências
       └─ riscos e dúvidas
            ↓
Redutor determinístico
  └─ deduplicação, ordenação temporal e resolução conservadora
            ↓
SLM — redação no template do usuário
            ↓
Validador factual e estrutural
  ├─ toda afirmação relevante aponta para evidência
  ├─ números/datas/nomes conferidos
  └─ falha explícita; nunca inventa para preencher campo
```

O formato intermediário será versionado e independente da interface. Isso permite trocar modelo, quantização ou runtime sem alterar o contrato do produto.

## 3. Diagnóstico do experimento anterior

O servidor IA já contém um adapter QLoRA para `Qwen3-4B-Instruct-2507`. Ele é útil como evidência de pesquisa, mas não está apto para publicação.

| Achado | Severidade | Consequência |
| --- | --- | --- |
| 540 exemplos de treino/validação foram rejeitados por ultrapassar 1.024 tokens; restaram 467/86 | Crítica | o modelo aprendeu principalmente reuniões curtas e não representa o uso central do produto |
| 24 de 36 casos do teste foram descartados pelo mesmo limite | Crítica | a avaliação automática ignorou 66,7% do teste e não mede reuniões longas |
| Fontes supervisionadas em inglês, sem corpus humano PT-BR | Crítica | há desalinhamento de idioma, estilo, cultura de reunião e formato de ata |
| Três testes PT-BR separados terminaram com gate derivado `FAIL` | Crítica | houve negação de relação causal, transformação de pendência em decisão e decisão inventada |
| QMSum foi tratado como MIT integralmente | Alta | a licença do repositório/anotações não elimina a necessidade de rastrear direitos dos transcripts AMI, ICSI e comitês canadenses |
| ROUGE foi a principal métrica automática | Alta | similaridade lexical não prova suporte factual, responsáveis ou prazos |
| Juiz de 3B produziu notas e veredictos incoerentes | Alta | LLM-as-judge pequeno serve apenas como triagem; não pode liberar o produto |

O adapter existente permanece bloqueado e não será usado como ponto de partida para distribuição. A base Qwen3 ainda pode participar do bake-off; a falha observada é do sistema de dados, contexto, treino e avaliação, não uma condenação isolada do checkpoint.

## 4. Dados: decisão comercial e adequação

O catálogo versionado está em [`qapia-ai-dataset-registry.yaml`](qapia-ai-dataset-registry.yaml). A triagem técnica não substitui parecer jurídico sobre as revisões exatas baixadas.

### Allowlist inicial

| Dataset | Tarefa | Decisão | Papel proposto |
| --- | --- | --- | --- |
| AMIsum | ata/resumo | permitido com atribuição | estrutura geral de resumo de reunião; baixo peso por ser inglês e pequeno |
| AMI Meeting Corpus | reunião/áudio | permitido com atribuição | estrutura, turnos e, se aplicável, ASR/avaliação em inglês |
| ICSI Meeting Corpus | reunião/áudio | permitido com atribuição | diversidade de reuniões e extração baseada em evidência em inglês |
| Common Voice 27.0 Português | ASR | permitido, com termos operacionais | robustez acústica PT/PT-BR; fala lida, portanto não prova qualidade em reunião |
| Multilingual LibriSpeech Português | ASR | permitido com atribuição | robustez de fala lida; peso secundário |
| FLEURS `pt_br` | ASR | permitido com atribuição | avaliação e complemento pequeno de sotaques/locutores |

### Condicionais

- **QMSum:** usar somente subconjuntos AMI/ICSI após vincular cada arquivo ao corpus de origem, fixar commit, preservar avisos e excluir o domínio de comitês até revisão específica. As anotações MIT e os transcripts subjacentes devem ter proveniência separada.
- **Teams Meeting Transcripts (Kaggle):** o rótulo MIT não é suficiente. É necessário baixar o arquivo, calcular checksum e comprovar origem, consentimento e cadeia de direitos antes de qualquer uso.
- **Call center/conversas comerciais:** somente mediante contrato que autorize treino e distribuição de pesos derivados, com comprovação de consentimento, retenção e tratamento de dados pessoais.
- **Dados próprios QAP.ia:** são o ativo decisivo, mas exigem opt-in explícito, desidentificação, finalidade de treino, retenção definida e separação por reunião antes de entrar no pipeline.

### Bloqueados para treino comercial

MeetingBank, DialogSum, SAMSum, CORAA, C-ORAL-BRASIL e amostras públicas de call center com cláusulas NC/ND não entram no corpus comercial. Eles não devem ser “misturados primeiro e revisados depois”. Quando os termos permitirem, um conjunto bloqueado pode ser usado apenas como benchmark de pesquisa isolado, sem contaminar pesos ou artefatos de distribuição.

## 5. SLMs para o bake-off

| Ordem | Modelo | Licença | Motivo | Risco a validar |
| --- | --- | --- | --- | --- |
| 1 | `Qwen/Qwen3-4B-Instruct-2507` | Apache-2.0 | 4B denso, multilingual, non-thinking, ecossistema GGUF/MLX maduro e integração anterior | o adapter anterior falhou; precisa de nova receita e benchmark limpo |
| 2 | `microsoft/Phi-4-mini-instruct` | MIT | 3,8B, contexto longo e português declarado | qualidade de redação PT-BR e conversão on-device |
| 3 | `HuggingFaceTB/SmolLM3-3B` | Apache-2.0 | 3B, português e stack aberta | capacidade factual em atas extensas |
| 4 | `ibm-granite/granite-4.0-micro` | Apache-2.0 | 3B, português e foco explícito em sumarização/extração | arquitetura híbrida e maturidade de exportação no Apple Silicon |

`Qwen3.5-4B` continua como baseline do app, mas não é a primeira escolha de especialização: traz componentes multimodais desnecessários ao fluxo textual e o experimento anterior encontrou atrito de conversão/empacotamento.

O vencedor não será escolhido por benchmark público. Todos receberão o mesmo prompt, contexto, quantização e conjunto cego do QAP.ia. Se nenhum 3–4B alcançar o gate de qualidade, o produto deve manter um modelo maior opcional ou rever o pipeline; o tamanho não pode vencer a fidelidade.

## 6. Estratégia de treino

### 6.1 ASR

1. estabelecer o baseline do Whisper Small atual em reuniões PT-BR reais;
2. separar teste por reunião, locutor e ambiente — nunca por trecho aleatório;
3. preparar LoRA/PEFT com Common Voice, MLS e FLEURS em baixo peso;
4. dar prioridade ao corpus próprio/licenciado de fala espontânea em reuniões;
5. medir WER/CER e também erro de números, datas, nomes, negações e omissões;
6. comparar o ganho do adapter contra melhorias do runtime atual, incluindo o problema de aceleração Metal.

### 6.2 Ata/resumo

O primeiro piloto terá tarefas explícitas, não apenas `transcript → texto livre`:

- `extract_evidence`: trecho → ledger JSON com evidências;
- `merge_evidence`: ledgers → estado consolidado sem duplicatas;
- `render_minutes`: estado consolidado + template → ata;
- `verify_claims`: ata + evidências → lista de violações;
- exemplos negativos em que responsável, prazo ou decisão estão ausentes.

Dados sintéticos podem ampliar cobertura de casos raros, mas nunca compor o conjunto final de aprovação. O alvo inicial é **300–500 reuniões PT-BR revisadas**, mais **pelo menos 75 reuniões inteiras reservadas** para teste cego. A unidade de split é a reunião e, quando possível, a organização/locutor.

### 6.3 Infraestrutura

O servidor `ai` foi validado em modo somente leitura:

- NVIDIA RTX 3080 com 12 GB de VRAM;
- 60 GB de RAM;
- volume `/mnt/llm` com mais de 800 GB livres na data da inspeção;
- ambiente Python 3.12 já compatível com PyTorch, Transformers, PEFT, bitsandbytes, TRL e Datasets.

A máquina é adequada para bake-off e QLoRA de 3–4B com gradient checkpointing, sequência controlada e acumulação de gradientes. Não é apropriada para full fine-tuning de 3–4B. O novo projeto terá ambiente próprio e artefatos versionados; o diretório do experimento anterior será somente referência.

## 7. Gates de qualidade

Nenhum modelo será integrado porque “parece melhor”. A promoção exige:

| Dimensão | Gate inicial |
| --- | --- |
| Afirmações factuais sem suporte | zero ocorrência crítica; taxa total menor ou igual a 1% em auditoria humana |
| Decisões e ações | precisão de evidência maior ou igual a 98%; cobertura maior ou igual a 90% |
| Responsável e prazo | nenhuma atribuição inventada nos casos críticos; precisão maior ou igual a 99% |
| Reuniões longas | 100% do conjunto deve ser processado; truncamento silencioso é falha |
| Preferência humana | pelo menos 75% de preferência contra o baseline atual, com avaliadores cegos |
| Português | naturalidade, concisão e fidelidade aprovadas separadamente; tradução literal não passa |
| Transcrição | melhora relativa mínima de 20% no erro composto do QAP.ia, incluindo entidades e números |
| Privacidade | áudio/transcript não saem do dispositivo no produto; corpus de treino segue consentimento e retenção |
| Performance | memória, energia e tempo medidos em M1, M2/M3 e M4; qualidade não é reduzida para atingir um número isolado |

Os limiares serão recalibrados depois do baseline, mas não relaxados retroativamente para aprovar um candidato.

## 8. Plano de execução

1. **Baseline reproduzível:** montar o harness e registrar saídas do Whisper Small e Qwen3.5 4B/9B atuais.
2. **Governança de dados:** materializar somente a allowlist com versões, checksums, proveniência e recibos de licença.
3. **Gold set PT-BR:** definir protocolo de consentimento, desidentificação e anotação; criar o conjunto cego.
4. **Bake-off sem treino:** testar os quatro SLMs no pipeline hierárquico para eliminar bases claramente inferiores.
5. **Piloto QLoRA:** treinar os dois melhores candidatos no servidor IA, com rastreabilidade total.
6. **Avaliação factual:** revisão humana cega, testes adversariais e comparação com o baseline e amostras de referência do Granola fornecidas legalmente pelo time.
7. **Empacotamento Apple:** gerar GGUF/MLX quantizados, medir perda de qualidade e escolher runtime.
8. **Integração em shadow mode:** o app produz o resultado candidato sem substituir a ata do usuário.
9. **Rollout:** promoção somente após todos os gates e plano de rollback.

## 9. Estrutura proposta no repositório

```text
AI/
├── configs/            # receitas versionadas, sem segredos
├── data-manifests/     # URLs, versões, licenças e checksums; nunca áudio bruto
├── evals/              # rubricas, casos canônicos e métricas
├── schemas/            # contratos do ledger e da ata
├── scripts/            # preparação, treino, conversão e benchmark
└── model-cards/        # limitações, resultados e THIRD_PARTY_NOTICES
```

Arquivos com gravações, transcripts reais, credenciais, pesos e caches permanecerão fora do Git. Os scripts devem recusar fontes não presentes na allowlist.

## 10. Fontes primárias

- [AMIsum — Hugging Face](https://huggingface.co/datasets/TalTechNLP/AMIsum)
- [AMI e ICSI Meeting Corpora — licença e downloads](https://groups.inf.ed.ac.uk/ami/download/)
- [QMSum — repositório e licença](https://github.com/Yale-LILY/QMSum)
- [Common Voice 27.0 — Português](https://mozilladatacollective.com/datasets/cmu5wui2w00e8nq07idithpm6)
- [Multilingual LibriSpeech](https://huggingface.co/datasets/facebook/multilingual_librispeech)
- [FLEURS](https://huggingface.co/datasets/google/fleurs)
- [MeetingBank](https://huggingface.co/datasets/huuuyeah/meetingbank)
- [DialogSum](https://github.com/cylnlp/dialogsum)
- [CORAA v1.1](https://huggingface.co/datasets/nilc-nlp/CORAA-v1.1)
- [Qwen3-4B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)
- [Phi-4-mini-instruct](https://huggingface.co/microsoft/Phi-4-mini-instruct)
- [SmolLM3-3B](https://huggingface.co/HuggingFaceTB/SmolLM3-3B)
- [Granite 4.0 Micro](https://huggingface.co/ibm-granite/granite-4.0-micro)
