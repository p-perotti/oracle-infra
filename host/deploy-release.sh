#!/bin/sh
set -eu

usage() {
  echo "usage: deploy-release.sh --app-name NAME --release-id ID --payload-dir DIR --services 'SERVICE ...' --smoke-url URL [--operation deploy|redeploy|recovery] [--failure-mode none|promotion|rollback] [--lock-timeout SECONDS] [--retention-count COUNT]" >&2
  exit 64
}

app_name=""
release_id=""
payload_dir=""
services=""
smoke_url=""
lock_timeout=60
health_timeout=180
retention_count=5
failure_mode=none
operation=deploy

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
    *) usage ;;
  esac
done

case "$app_name" in
  [a-z0-9]* ) ;;
  *) usage ;;
esac
case "$app_name" in *[!a-z0-9-]*|-*|*-|'') usage ;; esac
case "$release_id" in *[!A-Za-z0-9._-]*|'') usage ;; esac
case "$lock_timeout" in *[!0-9]*|'') usage ;; esac
case "$health_timeout" in *[!0-9]*|'') usage ;; esac
case "$retention_count" in *[!0-9]*|'') usage ;; esac
case "$failure_mode" in none|promotion|rollback) ;; *) usage ;; esac
case "$operation" in deploy|redeploy|recovery) ;; *) usage ;; esac
[ "$retention_count" -ge 2 ] || usage
test -n "$payload_dir" && test -n "$services" && test -n "$smoke_url" || usage
for service in $services; do
  case "$service" in
    [A-Za-z0-9]* ) ;;
    *) usage ;;
  esac
  case "$service" in *[!A-Za-z0-9_.-]*|-*|'') usage ;; esac
done

deploy_root="${APP_DEPLOY_ROOT:-${ORACLE_INFRA_SRV_ROOT:-/srv}/$app_name}"
namespace_root="${ORACLE_INFRA_SRV_ROOT:-$(dirname "$deploy_root")}"
config_dir="${APP_CONFIG_DIR:-${ORACLE_INFRA_ETC_ROOT:-/etc}/$app_name}"
runtime_env="${APP_RUNTIME_ENV_FILE:-$config_dir/runtime.env}"
secrets_dir="${APP_SECRETS_DIR:-$config_dir/secrets}"
lock_file="${ORACLE_INFRA_LOCK_FILE:-/run/lock/oracle-infra-deploy.lock}"
docker_bin="${ORACLE_INFRA_DOCKER_BIN:-docker}"
curl_bin="${ORACLE_INFRA_CURL_BIN:-curl}"
release_dir="$deploy_root/releases/$release_id"
state_dir="$deploy_root/state"
active_file="$state_dir/active-release"
previous_file="$state_dir/previous-release"
failed_file="$state_dir/failed-release"

test -f "$payload_dir/compose.yml" || { echo "Release payload is missing compose.yml" >&2; exit 65; }
test -f "$payload_dir/release.env" || { echo "Release payload is missing release.env" >&2; exit 65; }
test -x "$payload_dir/smoke-test" || { echo "Release payload is missing executable smoke-test" >&2; exit 65; }
test -f "$runtime_env" || { echo "Runtime environment file is missing: $runtime_env" >&2; exit 66; }
test -d "$secrets_dir" || { echo "Runtime secrets directory is missing: $secrets_dir" >&2; exit 66; }
manifest_release="$(sed -n 's/^RELEASE_ID=//p' "$payload_dir/release.env")"
test "$manifest_release" = "$release_id" || { echo "Release manifest identity mismatch" >&2; exit 65; }

image_count=0
while IFS='=' read -r key value; do
  case "$key" in
    RELEASE_ID) ;;
    *_IMAGE)
      case "$value" in
        ghcr.io/*@sha256:*) ;;
        *) echo "Image $key is not an immutable GHCR digest" >&2; exit 65 ;;
      esac
      digest="${value##*@sha256:}"
      case "$digest" in *[!0-9a-f]*|'') echo "Image $key has a malformed digest" >&2; exit 65 ;; esac
      test "${#digest}" -eq 64 || { echo "Image $key has a malformed digest" >&2; exit 65; }
      image_count=$((image_count + 1))
      ;;
    '') ;;
    *) echo "Unsupported release manifest key: $key" >&2; exit 65 ;;
  esac
done <"$payload_dir/release.env"
test "$image_count" -gt 0 || { echo "Release manifest contains no images" >&2; exit 65; }

mkdir -p "$(dirname "$lock_file")" "$state_dir" "$deploy_root/releases"
exec 9>"$lock_file"
if ! flock -x -w "$lock_timeout" 9; then
  echo "LOCK_TIMEOUT lock=$lock_file app=$app_name release=$release_id wait_seconds=$lock_timeout" >&2
  exit 75
fi

filesystem_percent="${ORACLE_INFRA_FILESYSTEM_PERCENT:-}"
if [ -z "$filesystem_percent" ]; then
  filesystem_percent="$(df -P "$deploy_root" | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
fi
case "$filesystem_percent" in *[!0-9]*|'') echo 'Filesystem utilization is unavailable' >&2; exit 78;; esac
if [ "$filesystem_percent" -ge 90 ]; then
  echo "FILESYSTEM_BLOCKED app=$app_name used_percent=$filesystem_percent threshold=90" >&2
  exit 78
elif [ "$filesystem_percent" -ge 80 ]; then
  echo "FILESYSTEM_WARNING app=$app_name used_percent=$filesystem_percent threshold=80" >&2
elif [ "$filesystem_percent" -ge 70 ]; then
  echo "FILESYSTEM_NOTICE app=$app_name used_percent=$filesystem_percent threshold=70" >&2
fi

previous_release=""
if [ -s "$active_file" ]; then
  previous_release="$(tr -d '\r\n' <"$active_file")"
fi

temporary_release="$deploy_root/releases/.${release_id}.tmp.$$"
trap 'rm -rf "$temporary_release"' EXIT HUP INT TERM
mkdir -p "$temporary_release"
cp -R "$payload_dir/." "$temporary_release/"
mv "$temporary_release/release.env" "$temporary_release/deployment.env"
if [ -e "$release_dir" ]; then
  if ! diff -qr "$temporary_release" "$release_dir" >/dev/null; then
    echo "Release identity already exists with a different immutable payload: $release_id" >&2
    exit 65
  fi
  rm -rf "$temporary_release"
else
  mv "$temporary_release" "$release_dir"
fi
trap - EXIT HUP INT TERM

compose() {
  target_dir="$1"
  shift
  APP_DEPLOY_ROOT="$deploy_root" \
  APP_CONFIG_DIR="$config_dir" \
  APP_RUNTIME_ENV_FILE="$runtime_env" \
  APP_SECRETS_DIR="$secrets_dir" \
  "$docker_bin" compose \
    --project-name "$app_name" \
    --env-file "$runtime_env" \
    --env-file "$target_dir/deployment.env" \
    --file "$target_dir/compose.yml" "$@"
}

smoke() {
  target_dir="$1"
  expected_release="$2"
  ORACLE_INFRA_CURL_BIN="$curl_bin" "$target_dir/smoke-test" "$smoke_url" "$expected_release"
}

activate() {
  activated_release="$1"
  activated_dir="$deploy_root/releases/$activated_release"
  printf '%s\n' "$activated_release" >"$active_file.tmp.$$"
  mv "$active_file.tmp.$$" "$active_file"
  ln -sfn "$activated_dir" "$deploy_root/current.tmp.$$"
  mv -Tf "$deploy_root/current.tmp.$$" "$deploy_root/current"
}

retain_releases() {
  removed_images_file="$(mktemp "$state_dir/.removed-images.XXXXXX")"
  protected_images_file="$(mktemp "$state_dir/.protected-images.XXXXXX")"
  kept=0
  find "$deploy_root/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' \
    | sort -rn \
    | while IFS=' ' read -r _modified candidate; do
        case "$candidate" in *[!A-Za-z0-9._-]*|.*|'') continue ;; esac
        kept=$((kept + 1))
        if [ "$kept" -le "$retention_count" ] \
          || [ "$candidate" = "$release_id" ] \
          || [ "$candidate" = "$previous_release" ]; then
          continue
        fi
        sed -n 's/^[A-Z0-9_]*_IMAGE=//p' \
          "$deploy_root/releases/$candidate/deployment.env" >>"$removed_images_file"
        rm -rf -- "$deploy_root/releases/$candidate"
        printf 'RETENTION removed app=%s release=%s\n' "$app_name" "$candidate"
      done

  find "$namespace_root" -path '*/releases/*/deployment.env' -type f -print \
    | while IFS= read -r manifest; do
        sed -n 's/^[A-Z0-9_]*_IMAGE=//p' "$manifest"
      done \
    | sort -u >"$protected_images_file"

  sort -u "$removed_images_file" \
    | while IFS= read -r image; do
        test -n "$image" || continue
        if grep -F -x -- "$image" "$protected_images_file" >/dev/null; then
          continue
        fi
        if "$docker_bin" image rm "$image"; then
          printf 'IMAGE_RETENTION removed app=%s image=%s\n' "$app_name" "$image"
        else
          printf 'IMAGE_RETENTION preserved app=%s image=%s reason=in-use-or-removal-failed\n' \
            "$app_name" "$image" >&2
        fi
      done

  rm -f "$removed_images_file" "$protected_images_file"
}

rollback() {
  test -n "$previous_release" || {
    echo "Rollback unavailable: no previous release is active" >&2
    return 1
  }
  rollback_dir="$deploy_root/releases/$previous_release"
  test -f "$rollback_dir/compose.yml" \
    && test -f "$rollback_dir/deployment.env" \
    && test -x "$rollback_dir/smoke-test" || {
      echo "Rollback payload is incomplete for release $previous_release" >&2
      return 1
    }
  if [ "$failure_mode" = rollback ]; then
    echo "Controlled rollback failure requested for app=$app_name release=$release_id" >&2
    return 1
  fi
  # shellcheck disable=SC2086 -- service tokens were validated above.
  compose "$rollback_dir" pull $services \
    && compose "$rollback_dir" up --detach --no-deps --wait --wait-timeout "$health_timeout" $services \
    && smoke "$rollback_dir" "$previous_release" \
    && activate "$previous_release"
}

promotion_succeeded=true
# shellcheck disable=SC2086 -- service names are validated by Compose and intentionally split.
compose "$release_dir" pull $services || promotion_succeeded=false
if [ "$promotion_succeeded" = true ]; then
  # shellcheck disable=SC2086
  compose "$release_dir" up --detach --no-deps --wait --wait-timeout "$health_timeout" $services \
    || promotion_succeeded=false
fi
if [ "$promotion_succeeded" = true ]; then
  if [ "$failure_mode" = promotion ] || [ "$failure_mode" = rollback ]; then
    echo "Controlled promotion failure requested for app=$app_name release=$release_id" >&2
    promotion_succeeded=false
  fi
fi
if [ "$promotion_succeeded" = true ]; then
  smoke "$release_dir" "$release_id" || promotion_succeeded=false
fi

if [ "$promotion_succeeded" = false ]; then
  printf '%s\n' "$release_id" >"$failed_file.tmp.$$"
  mv "$failed_file.tmp.$$" "$failed_file"
  if [ -n "$previous_release" ]; then
    printf '%s\n' "$previous_release" >"$previous_file.tmp.$$"
    mv "$previous_file.tmp.$$" "$previous_file"
  fi
  echo "Promotion failed for $app_name release $release_id; starting rollback" >&2
  if rollback; then
    printf 'RESULT outcome=rolled_back app=%s release=%s restored=%s operation=%s\n' \
      "$app_name" "$release_id" "$previous_release" "$operation"
    exit 1
  fi
  echo "CRITICAL: promotion and rollback both failed for app=$app_name release=$release_id" >&2
  printf 'RESULT outcome=rollback_failed app=%s release=%s previous=%s operation=%s\n' \
    "$app_name" "$release_id" "${previous_release:-none}" "$operation"
  exit 2
fi

if [ -n "$previous_release" ]; then
  printf '%s\n' "$previous_release" >"$previous_file.tmp.$$"
  mv "$previous_file.tmp.$$" "$previous_file"
else
  rm -f "$previous_file"
fi
rm -f "$failed_file"
activate "$release_id"
retain_releases

printf 'RESULT outcome=promoted app=%s release=%s previous=%s operation=%s\n' \
  "$app_name" "$release_id" "${previous_release:-none}" "$operation"
