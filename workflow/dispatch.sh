#!/bin/sh
set -eu

transport=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --transport)
      transport="${2:-}"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

case "$transport" in
  local)
    repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
    exec "$repo_root/host/deploy-release.sh" "$@"
    ;;
  ssh)
    repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
    app_name=""
    release_id=""
    payload_dir=""
    services=""
    smoke_url=""
    failure_mode="none"
    operation="deploy"
    lock_timeout="300"
    health_timeout="180"
    retention_count="5"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --app-name) app_name="${2:-}"; shift 2 ;;
        --release-id) release_id="${2:-}"; shift 2 ;;
        --payload-dir) payload_dir="${2:-}"; shift 2 ;;
        --services) services="${2:-}"; shift 2 ;;
        --smoke-url) smoke_url="${2:-}"; shift 2 ;;
        --operation) operation="${2:-}"; shift 2 ;;
        --failure-mode) failure_mode="${2:-}"; shift 2 ;;
        --lock-timeout) lock_timeout="${2:-}"; shift 2 ;;
        --health-timeout) health_timeout="${2:-}"; shift 2 ;;
        --retention-count) retention_count="${2:-}"; shift 2 ;;
        *) echo "Unsupported deploy argument: $1" >&2; exit 64 ;;
      esac
    done

    case "$app_name" in *[!a-z0-9-]*|-*|*-|'') echo 'Invalid app name' >&2; exit 64;; esac
    case "$release_id" in *[!A-Za-z0-9._-]*|'') echo 'Invalid release ID' >&2; exit 64;; esac
    case "$failure_mode" in none|promotion|rollback) ;; *) echo 'Invalid failure mode' >&2; exit 64;; esac
    case "$operation" in deploy|redeploy|recovery) ;; *) echo 'Invalid operation' >&2; exit 64;; esac
    case "$smoke_url" in https://*) ;; *) echo 'Smoke URL must use HTTPS' >&2; exit 64;; esac
    case "$smoke_url" in *[!A-Za-z0-9.:/_?\&=%~-]*) echo 'Smoke URL contains unsupported characters' >&2; exit 64;; esac
    for number in "$lock_timeout" "$health_timeout" "$retention_count"; do
      case "$number" in *[!0-9]*|'') echo 'Timeout and retention values must be integers' >&2; exit 64;; esac
    done
    for service in $services; do
      case "$service" in *[!A-Za-z0-9_.-]*|-*|'') echo 'Invalid service token' >&2; exit 64;; esac
    done
    test -n "$services" && test -d "$payload_dir" || { echo 'Release payload or services are missing' >&2; exit 64; }

    : "${DEPLOY_SSH_HOST:?}"
    : "${DEPLOY_SSH_USER:?}"
    : "${DEPLOY_SSH_KEY_FILE:?}"
    : "${DEPLOY_SSH_KNOWN_HOSTS_FILE:?}"
    : "${GHCR_READ_USERNAME:?}"
    : "${GHCR_READ_TOKEN:?}"
    ssh_base="-i $DEPLOY_SSH_KEY_FILE -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$DEPLOY_SSH_KNOWN_HOSTS_FILE"
    remote="$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST"
    transfer_root="${TMPDIR:-/tmp}/oracle-infra-$app_name-$release_id-$$"
    remote_root="/tmp/oracle-infra-$app_name-$release_id-$$"
    mkdir -p "$transfer_root"
    trap 'rm -rf "$transfer_root"' EXIT HUP INT TERM
    tar -C "$payload_dir" -czf "$transfer_root/payload.tgz" .
    cp "$repo_root/host/deploy-release.sh" "$transfer_root/deploy-release.sh"

    # shellcheck disable=SC2086 -- ssh options are fixed and paths cannot contain whitespace in hosted runners.
    printf '%s' "$GHCR_READ_TOKEN" | ssh $ssh_base "$remote" \
      "docker login ghcr.io --username '$GHCR_READ_USERNAME' --password-stdin" >/dev/null
    # shellcheck disable=SC2086
    ssh $ssh_base "$remote" "install -d -m 0700 '$remote_root'"
    # shellcheck disable=SC2086
    scp $ssh_base "$transfer_root/payload.tgz" "$transfer_root/deploy-release.sh" "$remote:$remote_root/"

    # The interpolated values above are constrained to shell-safe alphabets.
    # shellcheck disable=SC2086
    ssh $ssh_base "$remote" "set -eu
      trap 'rm -rf \"$remote_root\"' EXIT HUP INT TERM
      install -d -m 0700 '$remote_root/payload'
      tar -xzf '$remote_root/payload.tgz' -C '$remote_root/payload'
      chmod 0700 '$remote_root/deploy-release.sh'
      '$remote_root/deploy-release.sh' \
        --app-name '$app_name' \
        --release-id '$release_id' \
        --payload-dir '$remote_root/payload' \
        --services '$services' \
        --smoke-url '$smoke_url' \
        --operation '$operation' \
        --failure-mode '$failure_mode' \
        --lock-timeout '$lock_timeout' \
        --health-timeout '$health_timeout' \
        --retention-count '$retention_count'"
    ;;
  *)
    echo "Unsupported transport: ${transport:-none}" >&2
    exit 64
    ;;
esac
