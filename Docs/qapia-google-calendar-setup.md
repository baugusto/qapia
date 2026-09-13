# QAP.ia — configuração do Google Calendar

O aplicativo solicita somente `calendar.events.readonly`, além de `openid` e `email` para identificar a conta conectada. O fluxo usa a sessão de autenticação protegida do macOS, OAuth 2.0 com PKCE, o navegador do sistema e um retorno registrado pelo próprio app. Tokens ficam no Chaveiro do macOS.

## Preparar o Google Cloud

1. Crie ou selecione um projeto no Google Cloud Console.
2. Ative a **Google Calendar API**.
3. Configure a tela de consentimento OAuth. Durante testes, adicione os e-mails autorizados em **Test users**.
4. Adicione o escopo `https://www.googleapis.com/auth/calendar.events.readonly`.
5. Crie um OAuth Client ID do tipo **iOS**.
6. Informe o Bundle ID `br.com.qapia.app`.
7. Copie o Client ID terminado em `.apps.googleusercontent.com`.

## Compilar

Na versão 1.2, o Client ID do produto já está configurado no pacote. O parâmetro abaixo é necessário somente para substituir a credencial em outro ambiente:

```zsh
QAPIA_GOOGLE_CLIENT_ID="seu-client-id.apps.googleusercontent.com" bash Scripts/build-app-bundle.sh
```

Para gerar o instalador:

```zsh
QAPIA_GOOGLE_CLIENT_ID="seu-client-id.apps.googleusercontent.com" bash Scripts/package-standalone.sh
```

O Client ID identifica o aplicativo e não é um segredo. O script também registra automaticamente o esquema de retorno invertido exigido pelo Google. Nenhum Client Secret é necessário ou incluído no bundle.

> Use exclusivamente um Client ID do tipo **iOS**, vinculado ao Bundle ID `br.com.qapia.app`. Credenciais Web ou Desktop que exijam Client Secret não devem ser usadas neste pacote.

## Validação

1. Abra **Configurações** no QAP.ia.
2. Selecione **Conectar Google** e conclua o consentimento no navegador.
3. Confirme que a conta e o horário da última sincronização aparecem no app.
4. Verifique a próxima reunião em **Gravações**.
5. Inicie a gravação pelo cartão da agenda e confirme título, horário e participantes.

Antes da distribuição pública, publique a tela de consentimento e conclua a verificação OAuth exigida pelo Google para o escopo de calendário.
