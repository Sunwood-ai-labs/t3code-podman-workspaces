#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/pair.sh USER [--ttl 15m]
USAGE
}

(($# >= 1)) || { usage >&2; exit 2; }
USER_NAME=$1
shift
TTL=15m
while (($#)); do
  case $1 in
    --ttl)
      (($# >= 2)) || { usage >&2; exit 2; }
      TTL=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ $TTL =~ ^[1-9][0-9]*(s|m|h|d)$ ]] || die "TTL must be a positive duration such as 30s, 15m, 2h, or 1d"
load_config
load_users
require_configured_user "$USER_NAME"
BASE_URL=$(public_url "$USER_NAME")

exec podman exec "t3code-${USER_NAME}" t3 auth pairing create \
  --base-dir /data/t3 \
  --base-url "$BASE_URL" \
  --ttl "$TTL" \
  --label "$USER_NAME"
