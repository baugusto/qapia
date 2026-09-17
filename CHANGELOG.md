# Changelog

Todas as mudanças relevantes do QAP.ia são registradas neste arquivo.

> As notas das versões 1.0.0 a 1.2.1 foram reconstruídas a partir dos
> artefatos de distribuição, documentos de produto e registros de sprint
> disponíveis. A partir da 1.2.2, as notas refletem diretamente as entregas
> validadas de cada versão.

## [1.2.3] - 2026-09-17

Versão estável de referência.

### Adicionado

- Seletor persistente entre os modelos locais Qwen 3.5 4B e 9B nas Configurações.
- Verificação automática do modelo selecionado e download pelo Ollama quando ele ainda não estiver instalado.
- Suporte a subtópicos nos templates: uma linha iniciada por `-` ou por tabulação passa a pertencer ao tópico anterior.
- Testes de persistência da escolha do modelo, hierarquia dos templates e validação de atas com subtópicos.

### Alterado

- O Qwen 3.5 4B passa a ser a opção padrão, reduzindo o consumo de memória em Macs com configurações menores.
- O Qwen 3.5 9B permanece disponível para usuários que prefiram maior qualidade de síntese.
- A geração de atas respeita a hierarquia de tópicos e subtópicos do template selecionado.
- O modelo anteriormente instalado permanece disponível quando o usuário troca de opção.

### Corrigido

- Falsas rejeições de resumos quando números escritos por extenso na transcrição eram apresentados em algarismos na ata.
- Respostas válidas do Ollama rejeitadas por variações seguras de estrutura e formatação Markdown.
- Subtópicos interpretados incorretamente como seções principais independentes.

### Validação

- Suíte regressiva: 231 testes executados, 8 testes condicionais ignorados e nenhuma falha.
- Resumo validado com uma transcrição real de aproximadamente 30 minutos usando o Qwen 3.5 4B.
- Aplicativo e imagem DMG arm64 gerados e verificados para homologação local.

## [1.2.2] - 2026-09-16

### Adicionado

- Painel de diagnóstico nas Configurações com indicadores de estado para Ollama, modelo Qwen, Whisper e permissões necessárias.
- Ação para verificar novamente os pré-requisitos locais e apresentar orientações quando houver pendências.

### Alterado

- A preparação dos recursos locais passa a informar separadamente runtime, modelo e componentes necessários.
- Falhas de geração do resumo preservam a transcrição e permitem uma nova tentativa sem perda do conteúdo da reunião.

### Corrigido

- Rejeição intermitente de atas válidas quando a resposta do Ollama apresentava pequenas variações de Markdown.
- Mensagens genéricas de falha que não permitiam identificar qual pré-requisito local estava indisponível.
- Validação excessivamente rígida da estrutura do template após uma nova redação do resumo.

## [1.2.1] - 2026-09-11

### Adicionado

- Integração do Google Calendar para exibir eventos futuros e sugerir gravações.
- Uso do título, horário e participantes do evento como contexto da reunião.
- Autenticação OAuth 2.0 com PKCE pelo navegador do sistema.
- Armazenamento protegido da sessão Google no Chaveiro do macOS.
- Client ID do produto incluído no pacote para eliminar configuração manual no uso normal.

### Alterado

- A integração solicita somente leitura dos eventos necessários ao funcionamento da agenda.
- O fluxo de autenticação deixa de depender de Client Secret incorporado ao aplicativo.

### Corrigido

- Erro `client_secret is missing` ao tentar conectar o Google Calendar.
- Solicitação indevida de segredo OAuth em um aplicativo instalado no computador do usuário.

## [1.2.0] - 2026-09-11

### Adicionado

- Geração local de atas executivas com Ollama e Qwen 3.5.
- Botão para regenerar manualmente o resumo usando o template selecionado.
- Regeneração automática quando o usuário troca o template da reunião.
- Editor rich text com estilos básicos, negrito, itálico e listas.
- Exibição da data, hora e duração total da gravação.

### Alterado

- Apple Intelligence deixa de participar do pipeline de resumo.
- O resumo passa a ser uma síntese estratégica da conversa, em vez de uma seleção de trechos da transcrição.
- Conversas sociais, icebreakers e conteúdo fora da pauta são descartados da ata.
- O pipeline prioriza contexto, pontos principais, decisões, acordos, responsáveis, prazos, riscos e próximos passos.
- Os títulos e a organização do documento seguem o template selecionado.

### Corrigido

- Perda de formatação ao entrar no modo de edição do resumo.
- Exibição de marcações Markdown para o usuário durante a edição.
- Segunda barra de rolagem criada pelo editor.
- Editor que permanecia aberto depois de clicar fora da área de edição.
- Resumos que reproduziam frases da transcrição sem produzir síntese executiva.

## Série [1.1.x] - 2026-09-03 a 2026-09-11

A série 1.1 evoluiu do primeiro pacote standalone até a base funcional consolidada que antecedeu a versão 1.2.

### Adicionado

- Instalador standalone arm64 para homologação em Macs Apple Silicon.
- Captura simultânea de áudio do sistema e microfone, com segmentação por pausa e retomada.
- Runtime `whisper.cpp` incluído no aplicativo e preparação automática do modelo Whisper Small.
- Persistência local de reuniões, segmentos, transcrições, resumos e estado de processamento.
- Recuperação de gravações e processamentos interrompidos.
- Histórico pesquisável por título, participante, data, transcrição e resumo.
- Templates padrão e personalizados para diferentes tipos de reunião.
- Interface Signal Calm, modos claro e escuro e indicador flutuante durante a gravação.

### Alterado

- Transcrição otimizada para português, reuniões longas e múltiplos segmentos.
- Processamento de transcrição e resumo movido para segundo plano, permitindo navegar pelo aplicativo.
- Seleção de microfone aprimorada para preservar a qualidade de áudio ao usar headsets Bluetooth.
- Modelo Whisper e empacotamento ajustados para reduzir o tamanho do instalador sem depender de Homebrew ou FFmpeg.

### Corrigido

- Perda de segmentos após pausa, retomada, interrupção ou encerramento inesperado.
- Falhas ao combinar áudio parcialmente gravado ou com uma das fontes indisponível.
- Reinício duplicado de transcrição e conflitos ao iniciar uma nova gravação.
- Repetições, silêncio e artefatos comuns no pós-processamento da transcrição.
- Persistência incompleta de reuniões durante processamento em segundo plano.

## [1.0.0] - 2026-08-31

Primeira versão do MVP do QAP.ia para macOS.

### Adicionado

- Aplicativo nativo em SwiftUI para macOS 15 ou superior.
- Fluxo de iniciar, pausar, retomar e encerrar uma gravação.
- Captura local de áudio da reunião.
- Transcrição local com Whisper.
- Geração e cópia de resumo estruturado.
- Histórico local de reuniões.
- Interface inicial para templates de resumo.
- Permissões de microfone e áudio do sistema.
- Materiais iniciais de distribuição e submissão para a Mac App Store.

### Privacidade

- Áudio, transcrição e resumo armazenados localmente no Mac.
- Recursos principais disponíveis sem criação de conta.
- Nenhum conteúdo de reunião enviado ao desenvolvedor.
