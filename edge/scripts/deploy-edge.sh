#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

if ! docker network inspect edge >/dev/null 2>&1; then
  docker network create --driver bridge --attachable edge >/dev/null
fi

docker compose config --quiet
docker compose run --rm --no-deps caddy \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker compose up --detach caddy

printf 'Shared edge deployed.\n'
