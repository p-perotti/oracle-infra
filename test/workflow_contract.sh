#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/deploy.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$workflow" ]] || fail 'reusable deploy workflow is missing'

for contract in \
  'workflow_call:' \
  'environment_name:' \
  'artifact_name:' \
  'app_name:' \
  'release_id:' \
  'services:' \
  'smoke_url:' \
  'packages: read' \
  'cancel-in-progress: false' \
  'name: ${{ inputs.environment_name }}' \
  'repository: ${{ job.workflow_repository }}' \
  'ref: ${{ job.workflow_sha }}' \
  'DEPLOY_SSH_HOST: ${{ vars.DEPLOY_SSH_HOST }}' \
  'DEPLOY_SSH_USER: ${{ vars.DEPLOY_SSH_USER }}' \
  'DEPLOY_SSH_KNOWN_HOSTS: ${{ vars.DEPLOY_SSH_KNOWN_HOSTS }}' \
  'DEPLOY_SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}' \
  'GHCR_READ_TOKEN: ${{ github.token }}' \
  'actions/download-artifact@v4' \
  'release-package/release.tgz' \
  'tar -xzf release-package/release.tgz' \
  'workflow/dispatch.sh' \
  '$GITHUB_STEP_SUMMARY'; do
  grep -F -- "$contract" "$workflow" >/dev/null || fail "workflow is missing contract: $contract"
done

if grep -Eq 'secrets: inherit|OCI_(CLI|API|TENANCY)|PRODUCTION_SSH_|VM_(HOST|USER|SSH)' "$workflow"; then
  fail 'workflow contains inherited, control-plane, or legacy credentials'
fi

printf 'PASS: reusable workflow exposes only the generic caller and transport contract\n'
