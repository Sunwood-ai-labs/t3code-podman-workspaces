#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/uninstall.sh [--purge-volumes] [--user USER]

Stop and remove the deployment's installed units. Named volumes are preserved
unless --purge-volumes is supplied. --user may target a user already removed
from users.conf, for example to purge that user's preserved volumes later.
USAGE
}

PURGE_VOLUMES=0
SELECTED_USER=""
while (($#)); do
  case $1 in
    --purge-volumes) PURGE_VOLUMES=1; shift ;;
    --user)
      (($# >= 2)) || { usage >&2; exit 2; }
      SELECTED_USER=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

load_users
: "${HOME:?HOME must be set}"
UNIT_DIR="${HOME}/.config/containers/systemd"
T3_CONFIG_DIR="${HOME}/.config/t3code"

declare -a TARGET_USERS=()
if [[ -n $SELECTED_USER ]]; then
  validate_user "$SELECTED_USER" || exit 1
  if user_is_configured "$SELECTED_USER"; then
    die "remove $SELECTED_USER from users.conf and run scripts/render.sh plus scripts/install.sh before targeting it"
  fi
  if [[ -f ${UNIT_DIR}/t3code-caddy.container ]] && grep -Fq "t3code-${SELECTED_USER}.network" "${UNIT_DIR}/t3code-caddy.container"; then
    die "Caddy still references $SELECTED_USER; render and install the reduced users.conf first"
  fi
  TARGET_USERS=("$SELECTED_USER")
else
  TARGET_USERS=("${USERS[@]}")
  declare -a SEARCH_DIRS=("${BUILD_DIR}/quadlet" "$UNIT_DIR")
  for search_dir in "${SEARCH_DIRS[@]}"; do
    [[ -d $search_dir ]] || continue
    for unit_file in "$search_dir"/t3code-*.container "$search_dir"/t3code-*.network; do
      [[ -f $unit_file ]] || continue
      unit_name=${unit_file##*/}
      target_user=${unit_name#t3code-}
      target_user=${target_user%.*}
      [[ $target_user == caddy ]] && continue
      validate_user "$target_user" >/dev/null || continue
      if ! array_contains "$target_user" "${TARGET_USERS[@]}"; then
        TARGET_USERS+=("$target_user")
      fi
    done
  done
fi

if [[ -z $SELECTED_USER ]]; then
  if systemctl --user is-active --quiet t3code-caddy.service; then
    run_cmd systemctl --user stop t3code-caddy.service
  fi
  if podman container exists t3code-caddy; then
    run_cmd podman rm --force t3code-caddy
  else
    status=$?
    (( status == 1 )) || die "podman could not inspect container t3code-caddy (exit $status)"
  fi
fi

for user in "${TARGET_USERS[@]}"; do
  if systemctl --user is-active --quiet "t3code-${user}.service"; then
    run_cmd systemctl --user stop "t3code-${user}.service"
  fi
  if systemctl --user is-active --quiet "t3code-${user}-network.service"; then
    run_cmd systemctl --user stop "t3code-${user}-network.service"
  fi
  if podman container exists "t3code-${user}"; then
    run_cmd podman rm --force "t3code-${user}"
  else
    status=$?
    (( status == 1 )) || die "podman could not inspect container t3code-${user} (exit $status)"
  fi
  if podman network exists "t3code-${user}"; then
    run_cmd podman network rm "t3code-${user}"
  else
    status=$?
    (( status == 1 )) || die "podman could not inspect network t3code-${user} (exit $status)"
  fi
  run_cmd rm -f -- "${UNIT_DIR}/t3code-${user}.container" "${UNIT_DIR}/t3code-${user}.network"
done

if [[ -z $SELECTED_USER ]]; then
  shopt -s nullglob
  for unit_file in "$UNIT_DIR"/t3code-*.container "$UNIT_DIR"/t3code-*.network; do
    run_cmd rm -f -- "$unit_file"
  done
  run_cmd rm -f -- "${T3_CONFIG_DIR}/caddy/Caddyfile"
fi

run_cmd systemctl --user daemon-reload

if (( PURGE_VOLUMES == 1 )); then
  declare -a VOLUMES=()
  for user in "${TARGET_USERS[@]}"; do
    VOLUMES+=("t3code-${user}-home" "t3code-${user}-workspace" "t3code-${user}-data")
  done
  if ((${#VOLUMES[@]} == 0)); then
    printf 'No users selected; no volumes to purge.\n'
  else
    printf 'Volumes selected for deletion:\n'
    printf '  %s\n' "${VOLUMES[@]}"
    for volume in "${VOLUMES[@]}"; do
      if podman volume exists "$volume"; then
        run_cmd podman volume rm "$volume"
      else
        status=$?
        (( status == 1 )) || die "podman could not inspect volume $volume (exit $status)"
      fi
    done
  fi
else
  printf 'Named volumes and per-user env files were preserved.\n'
fi

printf 'Uninstalled %s.\n' "${SELECTED_USER:-all configured and installed users}"
