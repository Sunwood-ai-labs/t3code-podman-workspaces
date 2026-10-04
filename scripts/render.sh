#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_config
load_users

QUADLET_BUILD_DIR="${BUILD_DIR}/quadlet"
NETWORK_TEMPLATE="${REPO_ROOT}/quadlet/t3code-user.network.in"
CONTAINER_TEMPLATE="${REPO_ROOT}/quadlet/t3code-user.container.in"
mkdir -p "$QUADLET_BUILD_DIR"

[[ -r $NETWORK_TEMPLATE ]] || die "missing template: $NETWORK_TEMPLATE"
[[ -r $CONTAINER_TEMPLATE ]] || die "missing template: $CONTAINER_TEMPLATE"

# Remove only previously rendered per-user units. The Caddy unit is rendered
# by scripts/render-caddy.sh and shares this output directory.
shopt -s nullglob
for old_unit in "$QUADLET_BUILD_DIR"/t3code-*.network "$QUADLET_BUILD_DIR"/t3code-*.container; do
  old_name=${old_unit##*/}
  old_user=${old_name#t3code-}
  old_user=${old_user%.*}
  [[ $old_user == caddy ]] && continue
  if [[ $old_user =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    rm -f -- "$old_unit"
  fi
done

render_template() {
  local template=$1 output=$2 user=$3 line
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line//@USER@/$user}
    line=${line//@T3_IMAGE@/$T3_IMAGE}
    line=${line//@T3_PORT@/$T3_PORT}
    line=${line//@T3_MEMORY@/$T3_MEMORY}
    line=${line//@T3_CPUS@/$T3_CPUS}
    line=${line//@T3_PIDS_LIMIT@/$T3_PIDS_LIMIT}
    printf '%s\n' "$line"
  done < "$template" > "$output"
  chmod 0644 "$output"
}

for user in "${USERS[@]}"; do
  render_template "$NETWORK_TEMPLATE" "${QUADLET_BUILD_DIR}/t3code-${user}.network" "$user"
  render_template "$CONTAINER_TEMPLATE" "${QUADLET_BUILD_DIR}/t3code-${user}.container" "$user"
done

if [[ -f ${REPO_ROOT}/scripts/render-caddy.sh ]]; then
  bash "${REPO_ROOT}/scripts/render-caddy.sh"
else
  printf 'scripts/render-caddy.sh not present; skipped Caddy rendering.\n' >&2
fi

printf 'Rendered %d user(s) into %s\n' "${#USERS[@]}" "$QUADLET_BUILD_DIR"
