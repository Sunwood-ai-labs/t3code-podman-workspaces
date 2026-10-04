#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_users

printf '%-18s %-12s %-20s %s\n' USER SERVICE CONTAINER MEMORY
for user in "${USERS[@]}"; do
  service_name="t3code-${user}.service"
  container_name="t3code-${user}"
  service_state=$(systemctl --user is-active "$service_name" 2>/dev/null || true)
  [[ -n $service_state ]] || service_state=unknown

  if podman container exists "$container_name"; then
    container_state=$(podman inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || printf 'unknown')
    if [[ $container_state == running ]]; then
      memory=$(podman stats --no-stream --format '{{.MemUsage}}' "$container_name" 2>/dev/null || printf 'unavailable')
      [[ -n $memory ]] || memory=unavailable
    else
      memory=n/a
    fi
  else
    status=$?
    if (( status == 1 )); then
      container_state=missing
      memory=n/a
    else
      printf 'error: podman could not inspect container %s (exit %d)\n' "$container_name" "$status" >&2
      exit "$status"
    fi
  fi

  printf '%-18s %-12s %-20s %s\n' "$user" "$service_state" "$container_state" "$memory"
done
