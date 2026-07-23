#!/usr/bin/env bash
set -euo pipefail

TOKEN_FILE="${DUCKDNS_TOKEN_FILE:-/etc/oracle-infra/duckdns-token}"
DOMAINS_FILE="${DUCKDNS_DOMAINS_FILE:-/etc/oracle-infra/duckdns-domains}"
UPDATE_URL="${DUCKDNS_UPDATE_URL:-https://www.duckdns.org/update}"

die() {
  echo "DuckDNS update failed: $*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "curl is required"
[[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" && -r "$TOKEN_FILE" ]] \
  || die "token file must be a readable regular file: $TOKEN_FILE"
[[ -f "$DOMAINS_FILE" && ! -L "$DOMAINS_FILE" && -r "$DOMAINS_FILE" ]] \
  || die "domains file must be a readable regular file: $DOMAINS_FILE"

token_metadata="$(stat -c '%u:%a' "$TOKEN_FILE")"
[[ "$token_metadata" == "$(id -u):600" ]] \
  || die "token file must be owned by the service user with mode 0600"

token="$(tr -d '\r\n' < "$TOKEN_FILE")"
[[ "$token" =~ ^[A-Za-z0-9-]+$ ]] || die "token file is empty or malformed"

domains=()
declare -A seen_domains=()
while IFS= read -r domain || [[ -n "$domain" ]]; do
  domain="${domain%%#*}"
  domain="${domain#"${domain%%[![:space:]]*}"}"
  domain="${domain%"${domain##*[![:space:]]}"}"
  [[ -n "$domain" ]] || continue
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
    || die "invalid subdomain in $DOMAINS_FILE"
  (( ${#domain} <= 63 )) || die "subdomain exceeds 63 characters"
  [[ -z "${seen_domains[$domain]:-}" ]] || die "duplicate subdomain in $DOMAINS_FILE"
  seen_domains["$domain"]=1
  domains+=("$domain")
done < "$DOMAINS_FILE"

(( ${#domains[@]} > 0 )) || die "domains file contains no subdomains"
joined_domains="$(IFS=,; printf '%s' "${domains[*]}")"

# Feed the request through curl's stdin configuration so the token never
# appears in argv or process listings.
response="$(
  {
    printf 'url = "%s"\n' "$UPDATE_URL"
    printf 'get\n'
    printf 'silent\n'
    printf 'show-error\n'
    printf 'fail\n'
    printf 'connect-timeout = 10\n'
    printf 'max-time = 30\n'
    printf 'data-urlencode = "domains=%s"\n' "$joined_domains"
    printf 'data-urlencode = "token=%s"\n' "$token"
    printf 'data-urlencode = "ip="\n'
  } | curl --config -
)" || die "request failed"

[[ "$response" == "OK" ]] || die "provider rejected the update"

echo "DuckDNS update completed for ${#domains[@]} subdomain(s)."
