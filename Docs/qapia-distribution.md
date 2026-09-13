# QAP.ia — distribuição standalone

`Scripts/package-standalone.sh` cria um DMG versionado com o aplicativo e um atalho para `/Applications`. Quando `QAPIA_WHISPER_MODEL_PATH` aponta para o arquivo oficial validado `ggml-small.bin`, o modelo de transcrição também é incorporado ao bundle assinado e o pacote funciona sem download na primeira abertura. Sem essa opção, o QAP.ia baixa e valida o mesmo modelo quando necessário.

## Instalação local de homologação

Sem **Developer ID Application** e notarização Apple concluída, o script recusa gerar um arquivo que pareça distribuível. Para criar conscientemente um pacote apenas para homologação neste Mac, execute:

```zsh
QAPIA_ALLOW_LOCAL_PACKAGE=1 \
QAPIA_WHISPER_MODEL_PATH="/caminho/ggml-small.bin" \
bash Scripts/package-standalone.sh
```

Esse artefato recebe o sufixo `-local.dmg`. Ele mantém a validação de bibliotecas do Hardened Runtime, mas não é aceito pelo Gatekeeper em outros Macs e não substitui uma assinatura pública Apple.

## Distribuição em outros Macs

1. Disponibilize um certificado **Developer ID Application** no Chaveiro.
2. Configure o Client ID OAuth do tipo **iOS**, vinculado ao Bundle ID `br.com.qapia.app`.
3. Crie um perfil do `notarytool` no Chaveiro.
4. Execute:

```zsh
QAPIA_GOOGLE_CLIENT_ID="seu-client-id.apps.googleusercontent.com" \
QAPIA_NOTARIZE_PROFILE="qapia-notary" \
QAPIA_WHISPER_MODEL_PATH="/caminho/ggml-small.bin" \
bash Scripts/package-standalone.sh
```

O script registra o retorno do Google, assina o app e o framework, valida a assinatura, gera o DMG, exige que a Apple retorne o estado `Accepted`, aplica o ticket e confirma a aceitação pelo Gatekeeper. Sem `QAPIA_NOTARIZE_PROFILE`, ele só permite gerar um artefato identificado por `-local.dmg` com a opção explícita de homologação.

Para distribuição direta, o QAP.ia mantém a transcrição e o resumo no Mac. O resumo usa exclusivamente Ollama/Qwen pela interface local. A cada abertura, o app verifica os pré-requisitos e, quando necessário, baixa e valida a distribuição oficial assinada do Ollama e a variante Qwen 3.5 adequada à memória disponível. Não existe fallback extrativo apresentado como ATA.
