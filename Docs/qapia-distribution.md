# QAP.ia — distribuição standalone

`Scripts/package-standalone.sh` cria `Build/QAP.ia-0.4.1.dmg` com o aplicativo e um atalho para `/Applications`. Ao abrir o app pela primeira vez, o QAP.ia prepara automaticamente o Whisper, o serviço local de resumo e os modelos necessários, exibindo o andamento na própria interface.

## Instalação local de homologação

O certificado `QAPia Local Development` permite manter permissões estáveis neste Mac. O DMG gerado dessa forma serve para homologação local, mas não substitui uma assinatura pública Apple.

## Distribuição em outros Macs

1. Disponibilize um certificado **Developer ID Application** no Chaveiro.
2. Configure o Client ID OAuth do tipo **iOS**, vinculado ao Bundle ID `br.com.qapia.app`.
3. Crie um perfil do `notarytool` no Chaveiro.
4. Execute:

```zsh
QAPIA_GOOGLE_CLIENT_ID="seu-client-id.apps.googleusercontent.com" \
QAPIA_NOTARIZE_PROFILE="qapia-notary" \
bash Scripts/package-standalone.sh
```

O script registra o retorno do Google, assina o app e o framework, valida a assinatura, gera o DMG, envia para notarização e aplica o ticket quando `QAPIA_NOTARIZE_PROFILE` estiver definido.

Para distribuição direta, o QAP.ia mantém a transcrição e o resumo no Mac. O resumo usa o modelo de linguagem do sistema quando disponível e uma alternativa estruturada local nos demais computadores; não baixa nem executa um runtime de IA separado.
