#!/bin/sh
set -eu

destination="${1:-}"
test -n "$destination" || { echo 'Materializer destination is required' >&2; exit 64; }
case "$destination" in /|/*|../*|*/../*|*/..) echo 'Materializer destination must remain in the workspace' >&2; exit 64;; esac

action_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$action_dir/../../.." && pwd)"

install -d -m 0700 "$destination/workflow" "$destination/host"
install -m 0700 "$repo_root/workflow/dispatch.sh" "$destination/workflow/dispatch.sh"
install -m 0700 "$repo_root/host/deploy-release.sh" "$destination/host/deploy-release.sh"

echo "Pinned delivery mechanism materialized"
