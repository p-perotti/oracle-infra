# oracle-infra

Infraestrutura compartilhada da máquina Oracle ARM que hospeda produtos independentes. Este repositório público é o proprietário do mecanismo reutilizável de entrega, do lock de mutação do host, da borda Caddy e da atualização dos registros DuckDNS; ele não possui configuração interna, banco, credenciais de aplicação, tokens DNS ou credenciais do control plane da OCI.

## Fronteiras de responsabilidade

Cada produto continua proprietário de seu Compose, imagens, health checks, smoke test, banco, volumes, configuração de runtime e segredos. O `oracle-infra` recebe um artefato de release já formado e executa o mesmo contrato para promoção automática, redeploy, recuperação e exercícios controlados:

1. materializa o dispatcher e o entrypoint por uma action pública fixada por
   SHA completo;
2. baixa o artefato produzido pelos gates do caller;
3. usa o environment do consumidor para as variables de destino e recebe a
   chave por secret explícito do repositório consumidor;
4. autentica o usuário remoto no GHCR com o token efêmero do job;
5. transfere o payload e chama `host/deploy-release.sh`;
6. mantém o lock exclusivo `/run/lock/oracle-infra-deploy.lock` de pull até smoke/rollback;
7. promove todos os serviços de aplicação como uma release compatível; e
8. remove a credencial efêmera do registry ao terminar.

O entrypoint deriva `APP_DEPLOY_ROOT=/srv/<app>`, `APP_CONFIG_DIR=/etc/<app>`, `APP_RUNTIME_ENV_FILE=/etc/<app>/runtime.env` e `APP_SECRETS_DIR=/etc/<app>/secrets` a partir de `APP_NAME`. Overrides existem apenas para testes ou migrações explícitas e nunca são exportados globalmente no host. As operações `deploy`, `redeploy` e `recovery` atravessam esse mesmo entrypoint; uma release existente só pode ser reutilizada quando o payload é idêntico.

## Contrato do caller

O caller fixa `.github/workflows/deploy.yml` por SHA completo e concede `contents: read`, `actions: read` e `packages: read`. Os inputs obrigatórios são o nome do environment, nome da aplicação, identidade imutável da release, artefato, serviços promovíveis e URL HTTPS do smoke test. O job reutilizado declara o environment de deployment e lê:

- variables `DEPLOY_SSH_HOST`, `DEPLOY_SSH_USER` e `DEPLOY_SSH_KNOWN_HOSTS`;
- secret explícito `DEPLOY_SSH_PRIVATE_KEY`, armazenado no repositório ou na
  organização consumidora.

O GitHub não recebe segredos da aplicação. O artefato contém um único `release.tgz`, preservando permissões; dentro dele ficam `compose.yml`, `release.env`, um `smoke-test` executável e os demais arquivos de runtime do produto. `release.env` contém exatamente `RELEASE_ID` e uma ou mais variáveis terminadas em `_IMAGE`, sempre no formato `ghcr.io/...@sha256:<64 hex>`. O smoke test recebe a URL e a release esperada, devendo verificar a identidade pela fronteira pública.

```yaml
jobs:
  deploy:
    permissions:
      actions: read
      contents: read
      packages: read
    uses: p-perotti/oracle-infra/.github/workflows/deploy.yml@0123456789abcdef0123456789abcdef01234567
    with:
      environment_name: OCI
      environment_url: https://product.example
      artifact_name: product-release-${{ github.sha }}
      app_name: product
      release_id: ${{ github.sha }}
      services: web worker
      smoke_url: https://product.example/health
    secrets:
      DEPLOY_SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}
```

## Bootstrap do host

Como root, prepare o lock compartilhado uma vez e reconecte as sessões dos usuários de deploy para atualizar seus grupos:

```sh
sudo host/bootstrap-lock.sh app-a-deploy app-b-deploy
```

Para cada produto, crie `/srv/<app>` com propriedade do usuário dedicado e mantenha `/etc/<app>/runtime.env` e `/etc/<app>/secrets/` fora dos checkouts. O arquivo público de runtime deve ser `0640`; o diretório de segredos, `0750`; e cada segredo, `0640` ou mais restrito. A rede externa `edge` precisa existir, mas somente o serviço HTTP do produto participa dela.

O caller deve apontar para um SHA integral, nunca para `master` ou tag mutável.
Como o Gobrewery é público, o GitHub exige que o workflow reutilizável também
esteja em um repositório público. A publicação deste repositório não publica
segredos: configurações e credenciais operacionais permanecem exclusivamente no
host ou nos environments dos consumidores.

`workflow_call` não consegue receber secrets pertencentes a environments do
caller; essa é uma restrição da plataforma. Por isso as variables não sensíveis
permanecem no environment `OCI`, enquanto a chave dedicada fica como secret do
repositório consumidor e é passada nominalmente — nunca por `secrets: inherit`.

O workflow comum obtém seus scripts por `.github/actions/materialize`, também
pinada por SHA completo. Callers públicos, por regra da plataforma, somente
podem consumir workflows hospedados em repositórios públicos.

## Promoção, rollback e retenção

O estado de cada produto fica em `/srv/<app>/state`: `active-release`, `previous-release` e, após falha, `failed-release`. Pull, recriação seletiva, health checks, smoke test e rollback ocorrem sob o mesmo lock. Falha de promoção com rollback saudável retorna erro e `RESULT outcome=rolled_back`; falha também no rollback retorna código 2 e `RESULT outcome=rollback_failed`. Antes do pull, ocupação de filesystem em 70% gera aviso inicial, 80% gera warning e 90% bloqueia a mutação; não há expansão automática.

A retenção remove somente diretórios antigos sob `/srv/<app>/releases`. A
release ativa e a anterior são preservadas. Para cada manifest removido, o
mecanismo tenta remover pelo digest exato somente as imagens que deixaram de ser
referenciadas por qualquer release retida do mesmo produto. O basename de cada
repositório de imagem deve ser `<app>` ou `<app>-*`, impedindo que um manifest
reivindique imagens do namespace de outro produto. Imagens em uso são preservadas
pelo próprio Docker e a limpeza nunca usa `--force`. O mecanismo não executa
`docker compose down`, prune global, remoção de volumes, limpeza da borda ou
mutação de outro namespace.

## Borda compartilhada

`edge/` versiona a stack existente `oci-edge`. Somente Caddy publica 80/443; `relicita-web` e `gobrewery-web` são os únicos destinos atualmente habilitados na rede externa. Alterar a borda é uma operação de infraestrutura independente e não faz parte do deploy de produto.

Validação segura antes de aplicar:

```sh
cd edge
docker compose config --quiet
docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
scripts/verify-edge.sh
```

### DuckDNS

O atualizador compartilhado fica em `edge/duckdns/update-duckdns.sh` e é
executado a cada cinco minutos por `oracle-infra-duckdns.timer`. O token nunca
entra no repositório nem na linha de comando: o host mantém:

- `/etc/oracle-infra/duckdns-token`, `root:root`, modo `0600`;
- `/etc/oracle-infra/duckdns-domains`, `root:root`, modo `0644`, com um
  subdomínio por linha.

Instalação ou atualização no host:

```sh
sudo install -D -o root -g root -m 0755 \
  edge/duckdns/update-duckdns.sh \
  /usr/local/libexec/oracle-infra-update-duckdns
sudo install -o root -g root -m 0644 \
  edge/duckdns/systemd/oracle-infra-duckdns.service \
  edge/duckdns/systemd/oracle-infra-duckdns.timer \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start oracle-infra-duckdns.service
sudo systemctl enable --now oracle-infra-duckdns.timer
```

O serviço oneshot deve ser comprovado antes de desabilitar qualquer timer
anterior. `systemctl enable --now` não desfaz automaticamente a habilitação se o
start falhar, portanto o status do serviço e o próximo disparo do timer devem ser
verificados explicitamente.

## Verificação local

```sh
bash test/deploy_acceptance.sh
bash test/workflow_contract.sh
bash test/duckdns_contract.sh
```

O fixture atravessa caller → dispatcher reutilizável → entrypoint do host com Docker e HTTPS substituídos apenas nas fronteiras externas. Ele prova promoção multi-imagem, rollback, falha dupla, timeout do lock, diretórios derivados e retenção sem tocar recursos persistentes.
