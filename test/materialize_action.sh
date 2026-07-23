#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

(
  cd "$work_root"
  "$repo_root/.github/actions/materialize/materialize.sh" materialized >/dev/null
)

cmp "$repo_root/workflow/dispatch.sh" "$work_root/materialized/workflow/dispatch.sh"
cmp "$repo_root/host/deploy-release.sh" "$work_root/materialized/host/deploy-release.sh"
[[ -x "$work_root/materialized/workflow/dispatch.sh" ]]
[[ -x "$work_root/materialized/host/deploy-release.sh" ]]

if "$repo_root/.github/actions/materialize/materialize.sh" ../outside >/dev/null 2>&1; then
  echo 'FAIL: materializer accepted a path outside the workspace' >&2
  exit 1
fi

echo 'PASS: public action materializes the exact pinned mechanism'
