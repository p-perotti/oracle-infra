#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/deploy.yml"
verify_workflow="$repo_root/.github/workflows/verify.yml"
download_artifact_sha=d3f86a106a0bac45b974a628896c90dbdf5c8093
checkout_sha=d23441a48e516b6c34aea4fa41551a30e30af803

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$workflow" ]] || fail 'reusable deploy workflow is missing'

for contract in \
  'workflow_call:' \
  'DEPLOY_SSH_PRIVATE_KEY:' \
  'required: true' \
  'environment_name:' \
  'environment_url:' \
  'artifact_name:' \
  'app_name:' \
  'release_id:' \
  'services:' \
  'smoke_url:' \
  'packages: read' \
  'cancel-in-progress: false' \
  'name: ${{ inputs.environment_name }}' \
  'url: ${{ inputs.environment_url }}' \
  'p-perotti/oracle-infra/.github/actions/materialize@' \
  'destination: .oracle-infra' \
  'DEPLOY_SSH_HOST: ${{ vars.DEPLOY_SSH_HOST }}' \
  'DEPLOY_SSH_USER: ${{ vars.DEPLOY_SSH_USER }}' \
  'DEPLOY_SSH_KNOWN_HOSTS: ${{ vars.DEPLOY_SSH_KNOWN_HOSTS }}' \
  'DEPLOY_SSH_PRIVATE_KEY: ${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}' \
  'GHCR_READ_TOKEN: ${{ github.token }}' \
  "actions/download-artifact@$download_artifact_sha" \
  'release-package/release.tgz' \
  'tar -xzf release-package/release.tgz' \
  'workflow/dispatch.sh' \
  '$GITHUB_STEP_SUMMARY'; do
  grep -F -- "$contract" "$workflow" >/dev/null || fail "workflow is missing contract: $contract"
done

grep -Eq 'p-perotti/oracle-infra/\.github/actions/materialize@[0-9a-f]{40}' "$workflow" \
  || fail 'materializer action is not pinned by full SHA'

grep -F "actions/checkout@$checkout_sha" "$verify_workflow" >/dev/null \
  || fail 'checkout action is not pinned to the reviewed full SHA'

if grep -REq 'uses:[[:space:]]+actions/[^@]+@v[0-9]+' "$repo_root/.github/workflows"; then
  fail 'an external action still uses a mutable major-version tag'
fi

if grep -F 'repository: ${{ job.workflow_repository }}' "$workflow" >/dev/null; then
  fail 'called workflow still attempts checkout with the caller-scoped token'
fi

if grep -Eq 'secrets: inherit|OCI_(CLI|API|TENANCY)|PRODUCTION_SSH_|VM_(HOST|USER|SSH)' "$workflow"; then
  fail 'workflow contains inherited, control-plane, or legacy credentials'
fi

printf 'PASS: reusable workflow exposes only the generic caller and transport contract\n'
