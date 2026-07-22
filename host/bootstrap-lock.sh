#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  printf 'bootstrap-lock.sh must run as root.\n' >&2
  exit 77
fi
if [[ "$#" -lt 1 ]]; then
  printf 'usage: bootstrap-lock.sh DEPLOY_USER [DEPLOY_USER ...]\n' >&2
  exit 64
fi

group=oracle-deploy
lock=/run/lock/oracle-infra-deploy.lock
tmpfiles=/etc/tmpfiles.d/oracle-infra.conf

getent group "$group" >/dev/null || groupadd --system "$group"
for user in "$@"; do
  id "$user" >/dev/null 2>&1 || { printf 'Unknown deploy user: %s\n' "$user" >&2; exit 66; }
  usermod --append --groups "$group" "$user"
done

printf 'f %s 0660 root %s -\n' "$lock" "$group" >"$tmpfiles"
systemd-tmpfiles --create "$tmpfiles"
chown root:"$group" "$lock"
chmod 0660 "$lock"

printf 'Shared deploy lock prepared for group %s. Reconnect deploy sessions before use.\n' "$group"
