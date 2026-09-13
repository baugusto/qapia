# Roadmap de atualização online do QAP.ia

## Objetivo

Verificar atualizações ao abrir o aplicativo, instalar somente pacotes autênticos e substituir apenas o bundle em `/Applications`. Reuniões, áudios, transcrições, resumos, modelos e credenciais permanecem fora do bundle, em `~/Library/Application Support/Qapia` e no Chaveiro, portanto não devem ser removidos por uma atualização.

## Recomendação técnica

Usar o Sparkle 2 com:

- `CFBundleVersion` sempre crescente;
- aplicativo assinado com **Developer ID Application** e notarizado;
- arquivo de atualização assinado com EdDSA;
- `appcast.xml` servido por HTTPS;
- verificação automática na abertura e opção **Buscar atualizações** em Configurações;
- download em segundo plano e instalação somente após a validação das duas assinaturas;
- backup do banco SwiftData antes de qualquer futura migração de schema.

O Sparkle substitui o `QAP.ia.app`, mas não toca em `Application Support/Qapia`. Mudanças no banco devem usar migrações versionadas e nunca excluir a store atual como estratégia de recuperação.

## Fase 0 — homologação interna com Google Drive

Uma pasta pública pode conter:

```text
QAPia Updates/
├── appcast.xml
├── QAP.ia-0.4.1.zip
└── QAP.ia-0.4.1.dmg
```

Fluxo de publicação:

1. Gerar o app com novo `CFBundleShortVersionString` e `CFBundleVersion`.
2. Assinar com Developer ID e notarizar.
3. Gerar o ZIP destinado ao Sparkle.
4. Executar `generate_appcast` para assinar o arquivo com a chave EdDSA guardada no Chaveiro.
5. Enviar o ZIP/DMG e o `appcast.xml` para a pasta do Drive.
6. Confirmar que os links retornam o arquivo diretamente, sem página HTML, login ou confirmação de download.
7. Testar a atualização em uma cópia do Mac com gravações existentes.

O Google Drive serve para homologação, mas não é o destino ideal para produção: links de download podem exigir redirecionamentos, autenticação ou uma página de confirmação para arquivos grandes. Se o appcast não puder ser obtido como arquivo HTTP direto, usar a Drive API com `alt=media` ou mover os artefatos para hospedagem estática.

## Fase 1 — atualização automática confiável

Hospedar `appcast.xml` e pacotes em GitHub Releases, Cloudflare R2 ou outro endereço HTTPS estável. Integrar Sparkle ao app, configurar `SUFeedURL` e `SUPublicEDKey`, verificar na abertura e permitir download automático. O usuário recebe uma mensagem antes da reinicialização do aplicativo.

## Fase 2 — segurança de dados e operação

- Criar backup datado da store antes de migrações.
- Validar áudio, transcrição e resumo após cada atualização de homologação.
- Manter os dois últimos pacotes para rollback do app, sem rollback destrutivo do banco.
- Publicar notas da versão no appcast.
- Registrar falhas de atualização localmente, sem incluir conteúdo das reuniões.
- Só liberar uma versão após testar atualização a partir das duas versões anteriores.

## Critérios de aceite

- A atualização nunca remove `Application Support/Qapia` nem itens do Chaveiro.
- Pacotes sem assinatura EdDSA ou assinatura Apple válida são recusados.
- Uma falha de rede mantém a versão atual funcionando.
- Processamentos em andamento permanecem persistidos e são retomados ao reabrir.
- O usuário consegue adiar a reinicialização quando estiver gravando uma reunião.
