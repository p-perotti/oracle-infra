# oracle-infra

Infraestrutura compartilhada da máquina Oracle ARM que hospeda produtos independentes. Este repositório privado é o proprietário do mecanismo reutilizável de entrega, do lock de mutação do host e da borda Caddy; ele não possui configuração interna, banco, credenciais de aplicação ou credenciais do control plane da OCI.

## Fronteiras de responsabilidade

Cada produto continua proprietário de seu Compose, imagens, health checks, smoke test, banco, volumes, configuração de runtime e segredos. O `oracle-infra` recebe um artefato de release já formado e executa o mesmo contrato para promoção automática, redeploy, recuperação e exercícios controlados:

1. baixa o artefato produzido pelos gates do caller;
2. usa somente o environment do repositório consumidor para obter o transporte SSH;
3. autentica o usuário remoto no GHCR com o token efêmero do job;
4. transfere o payload e chama `host/deploy-release.sh`;
5. mantém o lock exclusivo `/run/lock/oracle-infra-deploy.lock` de pull até smoke/rollback;
6. promove todos os serviços de aplicação como uma release compatível; e
7. remove a credencial efêmera do registry ao terminar.

O entrypoint deriva `APP_DEPLOY_ROOT=/srv/<app>`, `APP_CONFIG_DIR=/etc/<app>`, `APP_RUNTIME_ENV_FILE=/etc/<app>/runtime.env` e `APP_SECRETS_DIR=/etc/<app>/secrets` a partir de `APP_NAME`. Overrides existem apenas para testes ou migrações explícitas e nunca são exportados globalmente no host. As operações `deploy`, `redeploy` e `recovery` atravessam esse mesmo entrypoint; uma release existente só pode ser reutilizada quando o payload é idêntico.

## Contrato do caller

O caller fixa `.github/workflows/deploy.yml` por SHA completo e concede `contents: read`, `actions: read` e `packages: read`. Os inputs obrigatórios são o nome do environment, nome da aplicação, identidade imutável da release, artefato, serviços promovíveis e URL HTTPS do smoke test. O job reutilizado declara o environment no contexto do repositório consumidor e lê diretamente:

- variables `DEPLOY_SSH_HOST`, `DEPLOY_SSH_USER` e `DEPLOY_SSH_KNOWN_HOSTS`;
- secret `DEPLOY_SSH_PRIVATE_KEY`.

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
```

## Bootstrap do host

Como root, prepare o lock compartilhado uma vez e reconecte as sessões dos usuários de deploy para atualizar seus grupos:

```sh
sudo host/bootstrap-lock.sh relicita-deploy gobrewery-deploy
```

Para cada produto, crie `/srv/<app>` com propriedade do usuário dedicado e mantenha `/etc/<app>/runtime.env` e `/etc/<app>/secrets/` fora dos checkouts. O arquivo público de runtime deve ser `0640`; o diretório de segredos, `0750`; e cada segredo, `0640` ou mais restrito. A rede externa `edge` precisa existir, mas somente o serviço HTTP do produto participa dela.

O repositório hospedador deve permitir acesso aos workflows por repositórios consumidores autorizados em **Settings → Actions → General → Access**. O caller deve apontar para um SHA integral, nunca para `master` ou tag mutável.

## Promoção, rollback e retenção

O estado de cada produto fica em `/srv/<app>/state`: `active-release`, `previous-release` e, após falha, `failed-release`. Pull, recriação seletiva, health checks, smoke test e rollback ocorrem sob o mesmo lock. Falha de promoção com rollback saudável retorna erro e `RESULT outcome=rolled_back`; falha também no rollback retorna código 2 e `RESULT outcome=rollback_failed`. Antes do pull, ocupação de filesystem em 70% gera aviso inicial, 80% gera warning e 90% bloqueia a mutação; não há expansão automática.

A retenção remove somente diretórios antigos sob `/srv/<app>/releases`. A release ativa e a anterior são preservadas. O mecanismo não executa `docker compose down`, prune global, remoção de volumes, limpeza da borda ou mutação de outro namespace.

## Borda compartilhada

`edge/` versiona a stack existente `oci-edge`. Somente Caddy publica 80/443; `relicita-web` e `gobrewery-web` são os únicos destinos atualmente habilitados na rede externa. Alterar a borda é uma operação de infraestrutura independente e não faz parte do deploy de produto.

Validação segura antes de aplicar:

```sh
cd edge
docker compose config --quiet
docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
scripts/verify-edge.sh
```

## Verificação local

```sh
bash test/deploy_acceptance.sh
bash test/workflow_contract.sh
```

O fixture atravessa caller → dispatcher reutilizável → entrypoint do host com Docker e HTTPS substituídos apenas nas fronteiras externas. Ele prova promoção multi-imagem, rollback, falha dupla, timeout do lock, diretórios derivados e retenção sem tocar recursos persistentes.
