#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

edge_id="$(docker compose ps --quiet caddy)"
[[ -n "$edge_id" ]] || { printf 'Caddy is not running.\n' >&2; exit 1; }

docker network inspect edge >/dev/null
docker compose exec -T caddy \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

for port in 80 443; do
  mapfile -t publishers < <(docker ps --no-trunc --quiet --filter "publish=$port")
  if [[ "${#publishers[@]}" -ne 1 || "${publishers[0]}" != "$edge_id" ]]; then
    printf 'Port %s must be published exclusively by the shared Caddy container.\n' "$port" >&2
    exit 1
  fi
done

health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$edge_id")"
[[ "$health" = healthy ]] || { printf 'Caddy health is %s.\n' "$health" >&2; exit 1; }

printf 'Shared edge verification passed.\n'
