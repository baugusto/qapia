# Qapia — Sprint 0 UX/UI Specification

**Status:** Frames e componentes criados no Figma; visual aprovado; handoff SwiftUI em execução
**Data:** 24/08/2026
**Fonte visual:** [Qapia — Sprint 0 — UX UI](https://www.figma.com/design/6gtxk32ZmLR3Pz296Id74G)
**Implementação:** shell SwiftUI iniciado na Sprint 1; serviços reais permanecem fora do escopo

## 1. Objetivo

Definir uma interface macOS simples para os cinco estados necessários do MVP, deixando claros o estado atual, o tempo efetivamente gravado e a próxima ação disponível.

## 2. Princípios visuais

- Nativa, silenciosa e focada no conteúdo.
- Muito espaço negativo e baixa densidade visual.
- Sidebar discreta; conteúdo principal com hierarquia evidente.
- Poucos borders e superfícies quase planas.
- Controles nativos com cantos discretamente arredondados.
- SF Pro como família tipográfica.
- Referências de simplicidade: Granola, Apple Notes e Linear, sem copiar elementos visuais.
- A origem QAP deve permanecer apenas na história da marca; não usar estética de rádio, ondas, antenas ou códigos visuais de radioamadorismo.

## 3. Configuração do arquivo Figma

### Página

`Qapia / Sprint 0 — UX UI`

### Arquivo executado

- Arquivo: `Qapia — Sprint 0 — UX UI`
- Plano: `Projetos`
- Página de telas: `Qapia — Sprint 0 Screens`
- Página de componentes: `Qapia — Components`
- Tokens: collection `Qapia Tokens`, modo `Light`
- Frames criados: `S0 — Empty`, `S0 — Recording`, `S0 — Paused`, `S0 — Processing`, `S0 — Meeting Detail`

### Frames

Criar cinco frames de alta fidelidade, todos com `900 × 600 px`:

1. `01 — Empty`
2. `02 — Recording`
3. `03 — Paused`
4. `04 — Processing`
5. `05 — Meeting Detail`

O frame representa o conteúdo da janela do aplicativo. A barra de título nativa do macOS não deve ser desenhada como parte da interface Qapia.

### Auto Layout

- Frame raiz: layout horizontal.
- Sidebar: largura fixa de 220 px.
- Conteúdo: preencher o espaço restante.
- Padding principal do conteúdo: 32 px.
- Espaçamento vertical padrão entre blocos: 16 px.
- Componentes de ação: auto layout horizontal, gap de 8 px.
- Histórico: auto layout vertical, gap de 4 px.

## 4. Tokens visuais

Os valores abaixo são a referência inicial para o Figma e devem ser ajustados apenas se a revisão visual identificar problema real de legibilidade ou de linguagem nativa.

### Cores

| Token | Valor | Uso |
|---|---|---|
| `Canvas` | `#F7F7F8` | Fundo do conteúdo |
| `Sidebar` | `#F1F1F3` | Fundo da sidebar |
| `Primary` | `#1D1D1F` | Títulos e texto principal |
| `Secondary` | `#6E6E73` | Texto auxiliar e metadados |
| `Divider` | `#D8D8DC` | Divisores sutis |
| `Accent` | `#0A84FF` | Ação primária e seleção |
| `Recording` | `#FF453A` | Indicador de gravação |
| `Paused` | `#FF9F0A` | Indicador de pausa |
| `Success` | `#30D158` | Etapa concluída |
| `Surface` | `#FFFFFF` | Cartões e área de leitura quando necessário |

### Tipografia

| Estilo | Referência | Uso |
|---|---|---|
| Window title | SF Pro Display Semibold, 24/30 | Títulos de tela |
| Section title | SF Pro Display Semibold, 15/20 | Blocos de conteúdo |
| Body | SF Pro Text Regular, 13/18 | Texto principal |
| Secondary | SF Pro Text Regular, 12/16 | Metadados e instruções |
| Caption | SF Pro Text Regular, 11/14 | Labels auxiliares |
| Timer | SF Mono Medium, 48/56 | Tempo gravado |
| Button | SF Pro Text Medium, 13/18 | Ações |

### Espaçamento e forma

- Escala de espaçamento: 4, 8, 12, 16, 24 e 32 px.
- Raio padrão de controles: 8 px.
- Raio de superfície de leitura: 10 px.
- Altura mínima de botão: 32 px.
- Altura de item da sidebar: 32 px.
- Divider com 1 px e baixo contraste.
- Sombra somente quando necessária para separar a área de leitura; evitar cartões flutuantes em excesso.

## 5. Componentes reutilizáveis

### SidebarItem

- Ícone SF Symbols opcional, sempre acompanhado por texto.
- Label em 13 px.
- Estado normal: texto Primary/Secondary conforme hierarquia.
- Estado selecionado: superfície levemente contrastada, sem borda pesada.

### HistoryRow

- Título em 13 px, uma linha com truncamento.
- Horário e duração em 11/12 px Secondary.
- Altura entre 44 e 52 px conforme conteúdo.

### PrimaryButton

- Fundo Accent, texto branco.
- Label textual claro.
- Estado hover/focus visível.

### SecondaryButton

- Fundo transparente ou Surface.
- Texto Primary.
- Usado para Pausar, Retomar e ações secundárias.

### FinishButton

- Ação visualmente distinta, porém contida.
- Não usar vermelho intenso como preenchimento principal sem necessidade.
- Label obrigatório: `Finalizar`.

### StatusIndicator

- Ponto/ícone e texto; cor nunca é a única informação.
- Estados: `Gravando`, `Pausado`, `Áudio preparado`, `Transcrevendo`, `Gerando resumo`.

### TemplatePicker

- Controle nativo equivalente a Picker.
- Label `Template` acima ou à esquerda.
- Valor inicial: `Reunião Geral`.

### ContentTabs

- Duas opções: `Resumo` e `Transcrição`.
- A aba ativa deve ser identificada por texto, contraste e indicador sutil.

### CopyButton

- Label inicial: `Copiar resumo`.
- Após ação: feedback discreto `Copiado`.
- O feedback não deve deslocar o conteúdo principal.

## 6. Frame 01 — Empty State

### Composição

- Sidebar de 220 px à esquerda.
- `Nova gravação` selecionado no topo da navegação.
- `Histórico` logo abaixo.
- Área de histórico contém linhas fictícias somente para validar a densidade visual.
- Conteúdo centralizado verticalmente na área direita, com alinhamento horizontal central.

### Conteúdo

```text
Iniciar gravação

O áudio será armazenado localmente neste Mac.

[ Iniciar gravação ]
```

### Intenção

O primeiro contato deve comunicar privacidade e uma única ação principal. Não exibir métricas, cards, onboarding ou explicações técnicas.

## 7. Frame 02 — Recording

### Composição

- Sidebar permanece estável.
- Conteúdo centralizado na área direita.
- Status no topo do bloco principal com ponto vermelho e label `Gravando`.
- Contador em destaque, alinhado ao centro.
- Ações agrupadas abaixo do contador.

### Conteúdo

```text
● Gravando

00:32:48

[ Pausar ]     [ Finalizar ]
```

### Regras visuais

- O ponto vermelho deve ser visível, mas não pulsar de forma agressiva.
- O contador usa SF Mono e representa somente o tempo efetivamente gravado.
- `Pausar` é a ação primária disponível durante a captura.
- `Finalizar` deve ser reconhecível como encerramento, sem competir com o contador.

## 8. Frame 03 — Paused

### Composição

Manter a mesma geometria do Frame Recording para evitar mudança brusca de contexto.

### Conteúdo

```text
Pausado

00:32:48

[ Retomar ]     [ Finalizar ]
```

### Regras visuais

- Usar texto explícito `Pausado` e o token visual de pausa.
- O contador permanece exatamente no último tempo gravado.
- A ausência de captura durante a pausa não deve ser comunicada por animação.
- `Retomar` torna-se a ação principal.
- `Finalizar` permanece disponível.

## 9. Frame 04 — Processing

### Composição

- Título alinhado ao início do conteúdo: `Processando reunião`.
- Lista vertical de três etapas com ícone/estado, label e espaçamento generoso.
- Não exibir controles de gravação.

### Conteúdo

```text
Processando reunião

✓ Áudio preparado
● Transcrevendo
○ Gerando resumo
```

### Regras visuais

- A etapa concluída usa Success e texto normal.
- A etapa ativa usa Accent ou indicador de progresso sutil.
- A etapa futura usa Secondary e indicador vazio.
- Cada etapa deve ser compreensível sem depender da cor.
- A sequência visual reforça que o resumo só vem depois da transcrição.

## 10. Frame 05 — Meeting Detail

### Composição

- Título no topo do conteúdo: `Reunião DD/MM/YYYY - HH:mm`.
- TemplatePicker abaixo do título.
- Abas `Resumo` e `Transcrição`.
- Área de leitura com largura confortável e rolagem prevista na implementação.
- `Copiar resumo` alinhado ao final do bloco de ações.

### Conteúdo

```text
Reunião 24/08/2026 - 14:30

Template
[ Reunião Geral ▼ ]

[ Resumo ] [ Transcrição ]

## Resumo executivo

Conteúdo do resumo em Markdown...

[ Copiar resumo ]
```

### Regras visuais

- Resumo é a aba inicial.
- A transcrição deve ser acessível sem sair da Meeting Detail.
- O template selecionado deve ficar visível para contextualizar o resumo.
- O conteúdo deve priorizar leitura, não edição.
- `Copiar resumo` deve copiar o Markdown integral e exibir `Copiado` de forma discreta.

## 11. Sidebar e histórico

### Navegação

```text
Nova gravação

Histórico
  Hoje
  Ontem
  Esta semana
  Anteriores
```

O agrupamento pode aparecer como labels discretos. Cada Meeting exibe horário, título e duração. O título inicial é `Reunião DD/MM/YYYY - HH:mm`. Rename não faz parte da Sprint 0 nem da V1 inicial.

## 12. Fluxo visual entre frames

```text
Empty
  └── Iniciar gravação → Recording
Recording
  ├── Pausar → Paused
  └── Finalizar → Processing
Paused
  ├── Retomar → Recording
  └── Finalizar → Processing
Processing
  └── conclusão → Meeting Detail
Meeting Detail
  ├── Resumo ↔ Transcrição
  └── Copiar resumo → feedback Copiado
```

O fluxo visual não deve sugerir transcrição ou resumo durante Recording/Paused.

## 13. Checklist de handoff para SwiftUI

- [x] Dimensões e hierarquia dos cinco frames aprovadas.
- [x] Tokens convertidos em constantes de design apenas onde trouxerem valor.
- [x] Sidebar construída com NavigationSplitView ou equivalente nativo.
- [x] Componentes definidos antes das telas, sem design system extenso.
- [x] Estados de botão, foco e feedback de cópia documentados.
- [x] Conteúdo de exemplo substituível por dados mockados.
- [x] Nenhum serviço de áudio, Whisper ou Ollama incluído na Sprint 0.

## 14. Status e aprovação

A especificação foi transformada no arquivo Figma acima. A QA estrutural confirmou cinco frames de `900 × 600 px`, sidebar de `220 px`, tokens compartilhados e componentes reutilizáveis. O visual foi aprovado e o shell SwiftUI da Sprint 1 foi iniciado no pacote `Qapia/`.

**A Sprint 0 está encerrada. A validação de build e runtime da Sprint 1 deve ocorrer no Xcode antes de iniciar a Sprint 2.**
