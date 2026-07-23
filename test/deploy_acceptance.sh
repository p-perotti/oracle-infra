#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="${TMPDIR:-/tmp}/oracle-infra-acceptance.$$"
cleanup() {
  local exit_code=$?
  if [[ "${ORACLE_INFRA_KEEP_TEST_ROOT:-false}" = true ]]; then
    printf 'test root preserved at %s\n' "$work_root" >&2
  else
    rm -rf "$work_root"
  fi
  exit "$exit_code"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_equals() {
  local expected="$1" file="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  [[ "$(<"$file")" == "$expected" ]] || fail "expected $file to contain '$expected'"
}

assert_contains() {
  local expected="$1" file="$2"
  grep -F -- "$expected" "$file" >/dev/null || fail "expected '$expected' in $file"
}

make_fixture_payload() {
  local release_id="$1" payload="$2"
  mkdir -p "$payload"
  cp "$repo_root/test/fixtures/compose.yml" "$payload/compose.yml"
  cp "$repo_root/test/fixtures/smoke-test" "$payload/smoke-test"
  cat >"$payload/release.env" <<EOF
RELEASE_ID=$release_id
WEB_IMAGE=ghcr.io/example/fixture-web@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WORKER_IMAGE=ghcr.io/example/fixture-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
}

run_fixture_caller() {
  local release_id="$1" payload="$2" output="$3"
  APP_DEPLOY_ROOT="$work_root/srv/fixture" \
  APP_CONFIG_DIR="$work_root/etc/fixture" \
  APP_RUNTIME_ENV_FILE="$work_root/etc/fixture/runtime.env" \
  APP_SECRETS_DIR="$work_root/etc/fixture/secrets" \
  ORACLE_INFRA_LOCK_FILE="$work_root/run/oracle-infra-deploy.lock" \
  ORACLE_INFRA_DOCKER_BIN="$repo_root/test/fixtures/fake-docker" \
  ORACLE_INFRA_CURL_BIN="$repo_root/test/fixtures/fake-curl" \
  ORACLE_INFRA_FILESYSTEM_PERCENT="${FIXTURE_FILESYSTEM_PERCENT:-10}" \
  FAKE_DOCKER_LOG="$work_root/docker.log" \
  FAKE_SMOKE_LOG="$work_root/smoke.log" \
  FAKE_RUNNING_RELEASE_FILE="$work_root/running-release" \
  "$repo_root/test/fixtures/caller" \
    --app-name fixture \
    --release-id "$release_id" \
    --payload-dir "$payload" \
    --services "web worker" \
    --smoke-url https://fixture.example.test/health \
    --operation "${FIXTURE_OPERATION:-deploy}" \
    --failure-mode "${FIXTURE_FAILURE_MODE:-none}" \
    --lock-timeout "${FIXTURE_LOCK_TIMEOUT:-2}" \
    --retention-count "${FIXTURE_RETENTION_COUNT:-5}" >"$output" 2>&1
}

run_fixture_caller_with_derived_paths() {
  local release_id="$1" payload="$2" output="$3"
  ORACLE_INFRA_SRV_ROOT="$work_root/derived/srv" \
  ORACLE_INFRA_ETC_ROOT="$work_root/derived/etc" \
  ORACLE_INFRA_LOCK_FILE="$work_root/derived/run/oracle-infra-deploy.lock" \
  ORACLE_INFRA_DOCKER_BIN="$repo_root/test/fixtures/fake-docker" \
  ORACLE_INFRA_CURL_BIN="$repo_root/test/fixtures/fake-curl" \
  FAKE_DOCKER_LOG="$work_root/derived/docker.log" \
  FAKE_SMOKE_LOG="$work_root/derived/smoke.log" \
  FAKE_RUNNING_RELEASE_FILE="$work_root/derived/running-release" \
  "$repo_root/test/fixtures/caller" \
    --app-name fixture \
    --release-id "$release_id" \
    --payload-dir "$payload" \
    --services "web worker" \
    --smoke-url https://fixture.example.test/health >"$output" 2>&1
}

test_healthy_multi_image_promotion() {
  local payload="$work_root/payload-r1" output="$work_root/promotion.out"
  mkdir -p "$work_root/etc/fixture/secrets" "$work_root/persistent"
  : >"$work_root/etc/fixture/runtime.env"
  printf 'keep-me\n' >"$work_root/persistent/data"
  make_fixture_payload r1 "$payload"

  run_fixture_caller r1 "$payload" "$output"

  assert_file_equals r1 "$work_root/srv/fixture/state/active-release"
  assert_file_equals r1 "$work_root/running-release"
  assert_file_equals keep-me "$work_root/persistent/data"
  assert_contains ' pull web worker' "$work_root/docker.log"
  assert_contains ' up --detach --no-deps --wait --wait-timeout 180 web worker' "$work_root/docker.log"
  assert_contains 'RESULT outcome=promoted app=fixture release=r1 previous=none' "$output"
  assert_contains 'https://fixture.example.test/health r1' "$work_root/smoke.log"
}

test_failed_promotion_rolls_back_whole_release() {
  local r1="$work_root/rollback-r1" r2="$work_root/rollback-r2"
  local first_output="$work_root/rollback-first.out" failed_output="$work_root/rollback-failed.out"
  rm -rf "$work_root/srv/fixture" "$work_root/etc/fixture" "$work_root/docker.log" "$work_root/running-release"
  mkdir -p "$work_root/etc/fixture/secrets" "$work_root/persistent"
  : >"$work_root/etc/fixture/runtime.env"
  printf 'still-here\n' >"$work_root/persistent/data"
  make_fixture_payload r1 "$r1"
  make_fixture_payload r2 "$r2"
  run_fixture_caller r1 "$r1" "$first_output"

  if FAKE_FAIL_SMOKE_RELEASE=r2 run_fixture_caller r2 "$r2" "$failed_output"; then
    fail 'failed promotion unexpectedly succeeded'
  fi

  assert_file_equals r1 "$work_root/srv/fixture/state/active-release"
  assert_file_equals r1 "$work_root/srv/fixture/state/previous-release"
  assert_file_equals r2 "$work_root/srv/fixture/state/failed-release"
  assert_file_equals r1 "$work_root/running-release"
  assert_file_equals still-here "$work_root/persistent/data"
  assert_contains 'RESULT outcome=rolled_back app=fixture release=r2 restored=r1' "$failed_output"
  assert_contains 'https://fixture.example.test/health r1' "$work_root/smoke.log"
}

test_failed_rollback_is_unambiguous() {
  local r1="$work_root/critical-r1" r2="$work_root/critical-r2"
  local first_output="$work_root/critical-first.out" failed_output="$work_root/critical-failed.out"
  rm -rf "$work_root/srv/fixture" "$work_root/etc/fixture" "$work_root/docker.log" "$work_root/running-release"
  mkdir -p "$work_root/etc/fixture/secrets"
  : >"$work_root/etc/fixture/runtime.env"
  make_fixture_payload r1 "$r1"
  make_fixture_payload r2 "$r2"
  run_fixture_caller r1 "$r1" "$first_output"

  set +e
  FAKE_FAIL_SMOKE_RELEASES="r2 r1" run_fixture_caller r2 "$r2" "$failed_output"
  local status=$?
  set -e

  [[ "$status" -eq 2 ]] || fail "expected rollback failure exit 2, got $status"
  assert_file_equals r1 "$work_root/srv/fixture/state/active-release"
  assert_file_equals r2 "$work_root/srv/fixture/state/failed-release"
  assert_contains 'CRITICAL: promotion and rollback both failed' "$failed_output"
  assert_contains 'RESULT outcome=rollback_failed app=fixture release=r2 previous=r1' "$failed_output"
}

test_lock_contention_times_out_without_mutation() {
  local payload="$work_root/lock-r1" output="$work_root/lock-timeout.out"
  local lock_file="$work_root/run/oracle-infra-deploy.lock" ready="$work_root/lock-ready"
  rm -rf "$work_root/srv/fixture" "$work_root/etc/fixture" "$work_root/docker.log" "$work_root/running-release"
  mkdir -p "$work_root/etc/fixture/secrets" "$(dirname "$lock_file")"
  : >"$work_root/etc/fixture/runtime.env"
  make_fixture_payload r1 "$payload"

  (
    exec 8>"$lock_file"
    flock -x 8
    : >"$ready"
    sleep 5
  ) &
  local holder=$!
  while [[ ! -e "$ready" ]]; do sleep 0.05; done

  set +e
  FIXTURE_LOCK_TIMEOUT=1 run_fixture_caller r1 "$payload" "$output"
  local status=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [[ "$status" -eq 75 ]] || fail "expected lock timeout exit 75, got $status"
  assert_contains 'LOCK_TIMEOUT' "$output"
  assert_contains 'app=fixture release=r1 wait_seconds=1' "$output"
  [[ ! -e "$work_root/docker.log" ]] || fail 'lock timeout mutated Docker state'
  [[ ! -e "$work_root/srv/fixture/state/active-release" ]] || fail 'lock timeout changed active release'
}

test_retention_is_scoped_to_inactive_app_releases() {
  local output release payload
  rm -rf "$work_root/srv/fixture" "$work_root/etc/fixture" "$work_root/docker.log" "$work_root/running-release"
  mkdir -p "$work_root/etc/fixture/secrets" "$work_root/srv/fixture/shared" "$work_root/persistent"
  : >"$work_root/etc/fixture/runtime.env"
  printf 'other-resource\n' >"$work_root/srv/fixture/shared/keep"
  printf 'persistent-data\n' >"$work_root/persistent/data"
  for release in r1 r2 r3 r4; do
    payload="$work_root/retention-$release"
    output="$work_root/retention-$release.out"
    make_fixture_payload "$release" "$payload"
    case "$release" in
      r1) web=1; worker=a ;;
      r2) web=2; worker=b ;;
      r3) web=3; worker=c ;;
      r4) web=4; worker=d ;;
    esac
    sed -i \
      -e "s/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/$(printf '%0.s'"$web" {1..64})/" \
      -e "s/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/$(printf '%0.s'"$worker" {1..64})/" \
      "$payload/release.env"
    FIXTURE_RETENTION_COUNT=2 run_fixture_caller "$release" "$payload" "$output"
  done

  [[ ! -e "$work_root/srv/fixture/releases/r1" ]] || fail 'old release r1 was not removed'
  [[ ! -e "$work_root/srv/fixture/releases/r2" ]] || fail 'old release r2 was not removed'
  [[ -d "$work_root/srv/fixture/releases/r3" ]] || fail 'previous release r3 was removed'
  [[ -d "$work_root/srv/fixture/releases/r4" ]] || fail 'active release r4 was removed'
  assert_file_equals other-resource "$work_root/srv/fixture/shared/keep"
  assert_file_equals persistent-data "$work_root/persistent/data"
  assert_contains 'image rm ghcr.io/example/fixture-web@sha256:1111111111111111111111111111111111111111111111111111111111111111' "$work_root/docker.log"
  assert_contains 'image rm ghcr.io/example/fixture-worker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$work_root/docker.log"
  assert_contains 'image rm ghcr.io/example/fixture-web@sha256:2222222222222222222222222222222222222222222222222222222222222222' "$work_root/docker.log"
  assert_contains 'image rm ghcr.io/example/fixture-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$work_root/docker.log"
  if grep -Eq '(^| )(down|volume|system prune|image prune)( |$)' "$work_root/docker.log"; then
    fail 'retention invoked destructive Docker cleanup'
  fi
}

test_release_rejects_another_app_image_namespace() {
  local payload="$work_root/cross-namespace-r1" output="$work_root/cross-namespace.out"
  rm -rf "$work_root/srv/fixture" "$work_root/etc/fixture" "$work_root/docker.log" "$work_root/running-release"
  mkdir -p "$work_root/etc/fixture/secrets"
  : >"$work_root/etc/fixture/runtime.env"
  make_fixture_payload r1 "$payload"
  sed -i 's/fixture-web/shared-web/' "$payload/release.env"

  set +e
  run_fixture_caller r1 "$payload" "$output"
  local status=$?
  set -e

  [[ "$status" -eq 65 ]] || fail "cross-namespace image returned $status"
  assert_contains 'outside the fixture repository namespace' "$output"
  [[ ! -e "$work_root/docker.log" ]] || fail 'cross-namespace image mutated Docker state'
}

test_app_name_derives_isolated_directories() {
  local payload="$work_root/derived-payload" output="$work_root/derived.out"
  mkdir -p "$work_root/derived/etc/fixture/secrets"
  : >"$work_root/derived/etc/fixture/runtime.env"
  make_fixture_payload r1 "$payload"

  run_fixture_caller_with_derived_paths r1 "$payload" "$output"

  assert_file_equals r1 "$work_root/derived/srv/fixture/state/active-release"
  [[ -d "$work_root/derived/etc/fixture/secrets" ]] || fail 'derived secrets directory changed'
  assert_contains "env.APP_SECRETS_DIR=$work_root/derived/etc/fixture/secrets" "$work_root/derived/docker.log"
  assert_contains 'RESULT outcome=promoted app=fixture release=r1 previous=none' "$output"
}

test_controlled_failure_modes_use_the_same_entrypoint() {
  local r1="$work_root/drill-r1" r2="$work_root/drill-r2" r3="$work_root/drill-r3"
  local output="$work_root/drill.out"
  rm -rf "$work_root/srv/fixture" "$work_root/etc/fixture" "$work_root/docker.log" "$work_root/running-release"
  mkdir -p "$work_root/etc/fixture/secrets"
  : >"$work_root/etc/fixture/runtime.env"
  make_fixture_payload r1 "$r1"
  make_fixture_payload r2 "$r2"
  make_fixture_payload r3 "$r3"
  run_fixture_caller r1 "$r1" "$output"

  set +e
  FIXTURE_FAILURE_MODE=promotion run_fixture_caller r2 "$r2" "$output"
  local promotion_status=$?
  FIXTURE_FAILURE_MODE=rollback run_fixture_caller r3 "$r3" "$output"
  local rollback_status=$?
  set -e

  [[ "$promotion_status" -eq 1 ]] || fail "controlled promotion drill returned $promotion_status"
  [[ "$rollback_status" -eq 2 ]] || fail "controlled rollback drill returned $rollback_status"
  assert_file_equals r1 "$work_root/srv/fixture/state/active-release"
  assert_contains 'RESULT outcome=rollback_failed app=fixture release=r3 previous=r1' "$output"
}

test_redeploy_reuses_the_immutable_release() {
  local payload="$work_root/redeploy-r1" first="$work_root/redeploy-first.out" second="$work_root/redeploy-second.out"
  rm -rf "$work_root/srv/fixture" "$work_root/etc/fixture" "$work_root/docker.log" "$work_root/running-release"
  mkdir -p "$work_root/etc/fixture/secrets"
  : >"$work_root/etc/fixture/runtime.env"
  make_fixture_payload r1 "$payload"
  run_fixture_caller r1 "$payload" "$first"
  FIXTURE_OPERATION=redeploy run_fixture_caller r1 "$payload" "$second"

  assert_file_equals r1 "$work_root/srv/fixture/state/active-release"
  assert_contains 'RESULT outcome=promoted app=fixture release=r1 previous=r1 operation=redeploy' "$second"
}

test_filesystem_ceiling_blocks_before_docker_mutation() {
  local payload="$work_root/filesystem-r1" output="$work_root/filesystem.out"
  rm -rf "$work_root/srv/fixture" "$work_root/etc/fixture" "$work_root/docker.log" "$work_root/running-release"
  mkdir -p "$work_root/etc/fixture/secrets"
  : >"$work_root/etc/fixture/runtime.env"
  make_fixture_payload r1 "$payload"

  set +e
  FIXTURE_FILESYSTEM_PERCENT=90 run_fixture_caller r1 "$payload" "$output"
  local status=$?
  set -e

  [[ "$status" -eq 78 ]] || fail "filesystem ceiling returned $status"
  assert_contains 'FILESYSTEM_BLOCKED app=fixture used_percent=90 threshold=90' "$output"
  [[ ! -e "$work_root/docker.log" ]] || fail 'filesystem ceiling mutated Docker state'
}

test_healthy_multi_image_promotion
printf 'PASS: healthy multi-image promotion through caller -> workflow -> host entrypoint\n'
test_failed_promotion_rolls_back_whole_release
printf 'PASS: failed multi-image promotion rolls back to previous release\n'
test_failed_rollback_is_unambiguous
printf 'PASS: rollback failure is explicit and preserves active release identity\n'
test_lock_contention_times_out_without_mutation
printf 'PASS: host-wide lock contention times out without mutation\n'
test_retention_is_scoped_to_inactive_app_releases
printf 'PASS: retention removes only inactive releases and unreferenced images in the app namespace\n'
test_release_rejects_another_app_image_namespace
printf 'PASS: release manifests cannot claim another app image namespace\n'
test_app_name_derives_isolated_directories
printf 'PASS: APP_NAME derives isolated deploy and configuration directories\n'
test_controlled_failure_modes_use_the_same_entrypoint
printf 'PASS: controlled promotion and rollback drills use the common entrypoint\n'
test_redeploy_reuses_the_immutable_release
printf 'PASS: manual redeploy reuses the same immutable release and entrypoint\n'
test_filesystem_ceiling_blocks_before_docker_mutation
printf 'PASS: filesystem ceiling blocks before Docker mutation\n'
