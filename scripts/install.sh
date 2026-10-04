#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [--dry-run]

Install rendered Quadlet units and the Caddyfile for the current users.conf.
USAGE
}

DRY_RUN=0
case ${1-} in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

load_config
load_users
: "${HOME:?HOME must be set}"

QUADLET_BUILD_DIR="${BUILD_DIR}/quadlet"
UNIT_DIR="${HOME}/.config/containers/systemd"
T3_CONFIG_DIR="${HOME}/.config/t3code"
CADDYFILE_SOURCE="${BUILD_DIR}/caddy/Caddyfile"
CADDYFILE_DEST="${T3_CONFIG_DIR}/caddy/Caddyfile"

[[ -d $QUADLET_BUILD_DIR ]] || die "rendered Quadlet directory missing; run scripts/render.sh first"
[[ -f ${QUADLET_BUILD_DIR}/t3code-caddy.container ]] || die "Caddy Quadlet is missing; run scripts/render.sh after scripts/render-caddy.sh is available"
[[ -f $CADDYFILE_SOURCE ]] || die "rendered Caddyfile is missing: run scripts/render.sh after scripts/render-caddy.sh is available"
for user in "${USERS[@]}"; do
  [[ -f ${QUADLET_BUILD_DIR}/t3code-${user}.network ]] || die "rendered network unit missing for $user"
  [[ -f ${QUADLET_BUILD_DIR}/t3code-${user}.container ]] || die "rendered container unit missing for $user"
done

declare -a QUADLET_FILES=()
shopt -s nullglob
for unit_file in "$QUADLET_BUILD_DIR"/*.container "$QUADLET_BUILD_DIR"/*.network; do
  [[ -f $unit_file ]] && QUADLET_FILES+=("$unit_file")
done

declare -a STALE_USERS=()
for installed_unit in "$UNIT_DIR"/t3code-*.container "$UNIT_DIR"/t3code-*.network; do
  [[ -f $installed_unit ]] || continue
  unit_name=${installed_unit##*/}
  stale_user=${unit_name#t3code-}
  stale_user=${stale_user%.*}
  [[ $stale_user == caddy ]] && continue
  validate_user "$stale_user" >/dev/null || continue
  if ! array_contains "$stale_user" "${USERS[@]}" && ! array_contains "$stale_user" "${STALE_USERS[@]}"; then
    STALE_USERS+=("$stale_user")
  fi
done

for env_user in "${USERS[@]}"; do
  env_file="${T3_CONFIG_DIR}/${env_user}.env"
  [[ ! -L $env_file ]] || die "refusing to use a symlink for $env_file"
done

if (( DRY_RUN == 1 )); then
  run_cmd systemctl --user stop t3code-caddy.service
else
  if systemctl --user is-active --quiet t3code-caddy.service; then
    run_cmd systemctl --user stop t3code-caddy.service
  fi
fi

if ((${#STALE_USERS[@]} > 0)); then
  if (( DRY_RUN == 1 )); then
    run_cmd podman rm --force t3code-caddy
  elif podman container exists t3code-caddy; then
    run_cmd podman rm --force t3code-caddy
  else
    status=$?
    (( status == 1 )) || die "podman could not inspect container t3code-caddy (exit $status)"
  fi
fi

for stale_user in "${STALE_USERS[@]}"; do
  printf 'Removing stale user deployment %s; its named volumes will be preserved.\n' "$stale_user"
  if (( DRY_RUN == 1 )); then
    run_cmd systemctl --user stop "t3code-${stale_user}.service"
    run_cmd systemctl --user stop "t3code-${stale_user}-network.service"
    run_cmd podman rm --force "t3code-${stale_user}"
    run_cmd podman network rm "t3code-${stale_user}"
  else
    if systemctl --user is-active --quiet "t3code-${stale_user}.service"; then
      run_cmd systemctl --user stop "t3code-${stale_user}.service"
    fi
    if systemctl --user is-active --quiet "t3code-${stale_user}-network.service"; then
      run_cmd systemctl --user stop "t3code-${stale_user}-network.service"
    fi
    if podman container exists "t3code-${stale_user}"; then
      run_cmd podman rm --force "t3code-${stale_user}"
    else
      status=$?
      (( status == 1 )) || die "podman could not inspect container t3code-${stale_user} (exit $status)"
    fi
    if podman network exists "t3code-${stale_user}"; then
      run_cmd podman network rm "t3code-${stale_user}"
    else
      status=$?
      (( status == 1 )) || die "podman could not inspect network t3code-${stale_user} (exit $status)"
    fi
  fi
  run_cmd rm -f -- "${UNIT_DIR}/t3code-${stale_user}.container" "${UNIT_DIR}/t3code-${stale_user}.network"
done

run_cmd mkdir -p "$UNIT_DIR" "$T3_CONFIG_DIR"
run_cmd mkdir -p "${T3_CONFIG_DIR}/caddy"
for env_user in "${USERS[@]}"; do
  env_file="${T3_CONFIG_DIR}/${env_user}.env"
  if [[ ! -e $env_file ]]; then
    run_cmd install -D -m 0600 /dev/null "$env_file"
  elif [[ -f $env_file ]]; then
    run_cmd chmod 0600 "$env_file"
  else
    die "expected a regular environment file at $env_file"
  fi
done

for unit_file in "${QUADLET_FILES[@]}"; do
  run_cmd install -D -m 0644 "$unit_file" "${UNIT_DIR}/${unit_file##*/}"
done
run_cmd install -D -m 0644 "$CADDYFILE_SOURCE" "$CADDYFILE_DEST"
run_cmd systemctl --user daemon-reload

for user in "${USERS[@]}"; do
  run_cmd systemctl --user start "t3code-${user}-network.service"
done
for user in "${USERS[@]}"; do
  run_cmd systemctl --user restart "t3code-${user}.service"
done
run_cmd systemctl --user restart t3code-caddy.service

printf 'Installed and started units for %d user(s).\n' "${#USERS[@]}"
printf 'If the user manager must stay active after logout and start at boot, ask an administrator to run: loginctl enable-linger %s\n' "${USER:-$(id -un)}"
