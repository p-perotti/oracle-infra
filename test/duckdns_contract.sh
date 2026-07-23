#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

mkdir -p "$work_root/bin"
cat > "$work_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$CURL_ARGS_FILE"
cat > "$CURL_STDIN_FILE"
if [[ -n "${CURL_EXIT:-}" ]]; then
  exit "$CURL_EXIT"
fi
printf '%s\n' "${CURL_RESPONSE:-OK}"
EOF
chmod +x "$work_root/bin/curl"

token="test-token-that-must-not-reach-argv"
printf '%s\n' "$token" > "$work_root/token"
chmod 600 "$work_root/token"
printf '%s\n' gobrewery relicita > "$work_root/domains"

run_updater() {
  PATH="$work_root/bin:$PATH" \
    CURL_ARGS_FILE="$work_root/curl.args" \
    CURL_STDIN_FILE="$work_root/curl.stdin" \
    DUCKDNS_TOKEN_FILE="$work_root/token" \
    DUCKDNS_DOMAINS_FILE="$work_root/domains" \
    "$repo_root/edge/duckdns/update-duckdns.sh"
}

run_updater > "$work_root/stdout"
grep -Fx 'DuckDNS update completed for 2 subdomain(s).' "$work_root/stdout"
grep -Fx -- '--config' "$work_root/curl.args"
grep -Fx -- '-' "$work_root/curl.args"
if grep -Fq "$token" "$work_root/curl.args"; then
  echo "token leaked into curl argv" >&2
  exit 1
fi
grep -Fq 'data-urlencode = "domains=gobrewery,relicita"' "$work_root/curl.stdin"
grep -Fq "data-urlencode = \"token=$token\"" "$work_root/curl.stdin"
grep -Fq 'connect-timeout = 10' "$work_root/curl.stdin"
grep -Fq 'max-time = 30' "$work_root/curl.stdin"

chmod 644 "$work_root/token"
if run_updater > /dev/null 2> "$work_root/mode.err"; then
  echo "insecure token mode was accepted" >&2
  exit 1
fi
grep -Fq 'mode 0600' "$work_root/mode.err"
chmod 600 "$work_root/token"

printf '%s\n' 'invalid.domain' > "$work_root/domains"
if run_updater > /dev/null 2> "$work_root/invalid.err"; then
  echo "invalid subdomain was accepted" >&2
  exit 1
fi
grep -Fq 'invalid subdomain' "$work_root/invalid.err"

printf '%s\n' relicita relicita > "$work_root/domains"
if run_updater > /dev/null 2> "$work_root/duplicate.err"; then
  echo "duplicate subdomain was accepted" >&2
  exit 1
fi
grep -Fq 'duplicate subdomain' "$work_root/duplicate.err"

printf '%064d\n' 0 > "$work_root/domains"
if run_updater > /dev/null 2> "$work_root/length.err"; then
  echo "overlong subdomain was accepted" >&2
  exit 1
fi
grep -Fq 'exceeds 63 characters' "$work_root/length.err"

printf '%s\n' '# shared records' '' ' gobrewery ' 'relicita # product' > "$work_root/domains"
run_updater > "$work_root/comments.stdout"
grep -Fx 'DuckDNS update completed for 2 subdomain(s).' "$work_root/comments.stdout"

if CURL_RESPONSE=KO run_updater > /dev/null 2> "$work_root/rejected.err"; then
  echo "provider rejection was accepted" >&2
  exit 1
fi
grep -Fq 'provider rejected the update' "$work_root/rejected.err"
if grep -Fq "$token" "$work_root/rejected.err"; then
  echo "token leaked into provider rejection diagnostics" >&2
  exit 1
fi

if CURL_EXIT=22 run_updater > /dev/null 2> "$work_root/request.err"; then
  echo "curl failure was accepted" >&2
  exit 1
fi
grep -Fq 'request failed' "$work_root/request.err"
if grep -Fq "$token" "$work_root/request.err"; then
  echo "token leaked into request failure diagnostics" >&2
  exit 1
fi

service="$repo_root/edge/duckdns/systemd/oracle-infra-duckdns.service"
timer="$repo_root/edge/duckdns/systemd/oracle-infra-duckdns.timer"
grep -Fx 'ExecStart=/usr/local/libexec/oracle-infra-update-duckdns' "$service"
grep -Fx 'ReadOnlyPaths=/etc/oracle-infra' "$service"
grep -Fx 'TimeoutStartSec=45s' "$service"
grep -Fx 'AccuracySec=15s' "$timer"
grep -Fx 'Unit=oracle-infra-duckdns.service' "$timer"
if grep -Fq 'Persistent=' "$timer"; then
  echo "timer uses Persistent without an OnCalendar schedule" >&2
  exit 1
fi

echo "DuckDNS updater contract passed."
