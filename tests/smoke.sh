#!/usr/bin/env bash
# Post-install smoke test. Run on the deployment host as the deployment account
# after scripts/install.sh. It only reads state and sends unauthenticated
# requests: no pairing tokens are created or consumed.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../scripts/lib.sh
source "${SCRIPT_DIR}/../scripts/lib.sh"

load_config
load_users

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf 'ok    %s\n' "$1"
}
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$1"
}
check() {
  local description=$1 expected=$2 actual=$3
  if [[ $actual == "$expected" ]]; then
    ok "$description"
  else
    fail "$description (expected ${expected}, got ${actual:-nothing})"
  fi
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Verify against Caddy's internal root when it exists; a deployment that uses
# its own certificates is checked against the system trust store instead.
CA_ARGS=()
if podman exec t3code-caddy cat /data/caddy/pki/authorities/local/root.crt > "${WORK_DIR}/root.crt" 2>/dev/null; then
  CA_ARGS=(--cacert "${WORK_DIR}/root.crt")
fi

http_code() {
  # http_code <host> <url> [curl args...]; requests go to Caddy on this host.
  local host=$1 url=$2
  shift 2
  curl --silent --output /dev/null --max-time 10 --write-out '%{http_code}' \
    --resolve "${host}:${CADDY_HTTPS_PORT}:127.0.0.1" \
    --resolve "${host}:${CADDY_HTTP_PORT}:127.0.0.1" \
    "${CA_ARGS[@]}" "$@" "$url" 2>/dev/null || true
}

container_ip() {
  podman inspect "$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

check "t3code-caddy is running" running \
  "$(podman inspect t3code-caddy --format '{{.State.Status}}' 2>/dev/null || true)"

for user in "${USERS[@]}"; do
  name="t3code-${user}"
  host="${user}.${T3_DOMAIN}"
  url=$(public_url "$user")

  check "${user}: container is running" running \
    "$(podman inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)"
  check "${user}: container is healthy" healthy \
    "$(podman inspect "$name" --format '{{.State.Health.Status}}' 2>/dev/null || true)"
  check "${user}: no host ports are published" 'map[]' \
    "$(podman inspect "$name" --format '{{.HostConfig.PortBindings}}' 2>/dev/null || true)"
  check "${user}: runs as uid 1000" 1000 \
    "$(podman exec "$name" id -u 2>/dev/null || true)"
  check "${user}: network is isolated" strict \
    "$(podman network inspect "$name" --format '{{index .Options "isolate"}}' 2>/dev/null || true)"

  check "${user}: HTTPS through Caddy returns 200" 200 "$(http_code "$host" "${url}/")"
  check "${user}: HTTP redirects to HTTPS" 308 \
    "$(http_code "$host" "http://${host}:${CADDY_HTTP_PORT}/")"
  session=$(curl --silent --max-time 10 --resolve "${host}:${CADDY_HTTPS_PORT}:127.0.0.1" \
    "${CA_ARGS[@]}" "${url}/api/auth/session" 2>/dev/null || true)
  if [[ $session == *'"authenticated":false'* ]]; then
    ok "${user}: unpaired requests are not authenticated"
  else
    fail "${user}: unpaired requests are not authenticated"
  fi
  check "${user}: WebSocket without a session is rejected" 401 \
    "$(http_code "$host" "${url}/ws?orchestrationProtocol=1" --http1.1 \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')"
done

unknown_host="smoke-test-unknown.${T3_DOMAIN}"
check "unknown host is rejected over HTTP" 421 \
  "$(http_code "$unknown_host" "http://${unknown_host}:${CADDY_HTTP_PORT}/")"

# Workspaces must not reach each other, by name or by address.
for source_user in "${USERS[@]}"; do
  for target_user in "${USERS[@]}"; do
    [[ $source_user == "$target_user" ]] && continue
    target_ip=$(container_ip "t3code-${target_user}" 2>/dev/null || true)
    for target in "t3code-${target_user}" "$target_ip"; do
      [[ -n $target ]] || continue
      code=$(podman exec "t3code-${source_user}" curl --silent --output /dev/null \
        --max-time 3 --write-out '%{http_code}' "http://${target}:${T3_PORT}/" 2>/dev/null || true)
      check "${source_user} cannot reach ${target_user} at ${target}" 000 "${code:-000}"
    done
  done
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
