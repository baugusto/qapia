# Changelog

Todas as mudanças relevantes do QAP.ia são registradas neste arquivo.

## [1.2.3] - 2026-09-17

Versão estável de referência.

### Adicionado

- Seletor persistente entre os modelos locais Qwen 3.5 4B e 9B nas Configurações.
- Verificação automática do modelo selecionado e download pelo Ollama quando ele ainda não estiver instalado.
- Painel de diagnóstico dos pré-requisitos locais, com estado do Ollama, modelo de resumo, Whisper e permissões necessárias.
- Suporte a subtópicos nos templates: uma linha iniciada por `-` ou por tabulação passa a pertencer ao tópico anterior.
- Botão para regenerar manualmente o resumo com o template selecionado.
- Editor rich text para ajustar atas sem editar marcações Markdown diretamente.

### Alterado

- O Qwen 3.5 4B passa a ser a opção padrão, reduzindo o consumo de memória em Macs com configurações menores; o 9B continua disponível para priorizar qualidade.
- A geração de atas respeita a hierarquia de tópicos e subtópicos do template selecionado.
- O pipeline de resumo produz síntese executiva, elimina conversas sociais sem relação com a pauta e prioriza contexto, temas, decisões, acordos, responsáveis, prazos, riscos e próximos passos.
- A troca de template regenera automaticamente o resumo, mantendo a opção de regeneração manual.
- A edição do resumo preserva a apresentação visual e utiliza uma única área de rolagem.
- A integração com Google Calendar usa OAuth 2.0 com PKCE e não incorpora Client Secret no aplicativo.

### Corrigido

- Falsas rejeições de resumos quando números escritos por extenso na transcrição eram apresentados em algarismos na ata.
- Respostas válidas do Ollama rejeitadas por variações seguras de estrutura e formatação Markdown.
- Perda de formatação ao entrar no modo de edição do resumo.
- Retorno inconsistente do modo de edição para o modo de visualização.

### Validação

- Suíte regressiva: 231 testes aprovados e 8 testes condicionais ignorados, sem falhas.
- Resumo validado com uma transcrição real de aproximadamente 30 minutos usando o Qwen 3.5 4B.
- Aplicativo e imagem DMG arm64 gerados e verificados para homologação local.

## [1.2.1] - 2026-09-13

### Adicionado

- Integração inicial com Google Calendar para sugerir gravações e preencher título e participantes.
- Preparação local do Ollama e do modelo Qwen para geração privada de resumos.
- Regeneração automática do resumo ao trocar o template.

### Alterado

- Resumos passam a ser gerados localmente sem Apple Intelligence.
- Dados de reunião, transcrição e resumo permanecem no Mac.
