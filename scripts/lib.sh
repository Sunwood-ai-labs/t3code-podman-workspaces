#!/usr/bin/env bash
set -euo pipefail

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${LIB_DIR}/.." && pwd -P)"
BUILD_DIR="${REPO_ROOT}/build"
CONFIG_FILE="${REPO_ROOT}/config.env"
USERS_FILE="${REPO_ROOT}/users.conf"
export REPO_ROOT BUILD_DIR

declare -a USERS=()
USERS_LOADED=0
CONFIG_LOADED=0

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

trim_whitespace() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

validate_user() {
  local user=${1-}
  if [[ ! $user =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    printf 'error: invalid user name %q; use lowercase letters, digits, and hyphens, starting with a letter or digit\n' "$user" >&2
    return 1
  fi
  if [[ $user == caddy ]]; then
    printf 'error: user name caddy is reserved for the shared reverse proxy\n' >&2
    return 1
  fi
}

validate_port() {
  local value=$1 name=$2 port_number
  [[ $value =~ ^[0-9]+$ ]] || die "$name must be a numeric TCP port"
  port_number=$((10#$value))
  (( port_number >= 1 && port_number <= 65535 )) || die "$name must be between 1 and 65535"
}

load_config() {
  [[ -r $CONFIG_FILE ]] || die "cannot read $CONFIG_FILE"

  unset T3_DOMAIN T3_VERSION T3_IMAGE T3_PORT T3_MEMORY T3_CPUS T3_PIDS_LIMIT CADDY_IMAGE CADDY_HTTP_PORT CADDY_HTTPS_PORT
  local raw line key value first last required
  local -A config_keys=()
  while IFS= read -r raw || [[ -n $raw ]]; do
    raw=${raw%$'\r'}
    line=$(trim_whitespace "$raw")
    [[ -z $line || ${line:0:1} == '#' ]] && continue
    [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || die "invalid config.env line: $raw"

    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    if (( ${#value} >= 2 )); then
      first=${value:0:1}
      last=${value: -1}
      if [[ $first == '"' && $last == '"' ]] || [[ $first == "'" && $last == "'" ]]; then
        value=${value:1:${#value}-2}
      fi
    fi
    config_keys[$key]=1
    export "$key=$value"
  done < "$CONFIG_FILE"

  for required in T3_DOMAIN T3_IMAGE T3_PORT T3_MEMORY T3_CPUS T3_PIDS_LIMIT CADDY_IMAGE CADDY_HTTP_PORT CADDY_HTTPS_PORT; do
    [[ -n ${config_keys[$required]+x} ]] || die "config.env is missing $required"
    [[ -n ${!required} ]] || die "config.env has an empty $required"
  done

  [[ $T3_DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "T3_DOMAIN must be a hostname without a scheme or port"
  [[ $T3_DOMAIN != *..* ]] || die "T3_DOMAIN must not contain consecutive dots"
  [[ ! $T3_IMAGE =~ [[:space:]] ]] || die "T3_IMAGE must not contain whitespace"
  [[ ! $CADDY_IMAGE =~ [[:space:]] ]] || die "CADDY_IMAGE must not contain whitespace"
  [[ $T3_MEMORY =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || die "T3_MEMORY must be a positive number with an optional k, m, or g suffix"
  [[ $T3_CPUS =~ ^[0-9]+([.][0-9]+)?$ ]] || die "T3_CPUS must be a positive decimal value"
  [[ ! $T3_CPUS =~ ^0+([.]0+)?$ ]] || die "T3_CPUS must be greater than zero"
  [[ $T3_PIDS_LIMIT == -1 || $T3_PIDS_LIMIT =~ ^[1-9][0-9]*$ ]] || die "T3_PIDS_LIMIT must be a positive integer or -1"
  validate_port "$T3_PORT" T3_PORT
  validate_port "$CADDY_HTTP_PORT" CADDY_HTTP_PORT
  validate_port "$CADDY_HTTPS_PORT" CADDY_HTTPS_PORT
  CONFIG_LOADED=1
}

list_users() {
  [[ -r $USERS_FILE ]] || die "cannot read $USERS_FILE"

  local raw user candidate base
  local -a user_list=()
  local -A seen=()
  while IFS= read -r raw || [[ -n $raw ]]; do
    raw=${raw%$'\r'}
    user=$(trim_whitespace "$raw")
    [[ -z $user || ${user:0:1} == '#' ]] && continue
    validate_user "$user" || return 1
    [[ -z ${seen[$user]+x} ]] || die "duplicate user in users.conf: $user"
    seen[$user]=1
    user_list+=("$user")
  done < "$USERS_FILE"

  for candidate in "${user_list[@]}"; do
    if [[ $candidate == *-network ]]; then
      base=${candidate%-network}
      [[ -z ${seen[$base]+x} ]] || die "user names '$base' and '$candidate' generate colliding Quadlet service names"
    fi
  done
  if ((${#user_list[@]} > 0)); then
    printf '%s\n' "${user_list[@]}"
  fi
}

load_users() {
  local users_text user
  users_text=$(list_users) || return 1
  USERS=()
  if [[ -n $users_text ]]; then
    while IFS= read -r user; do
      USERS+=("$user")
    done <<< "$users_text"
  fi
  USERS_LOADED=1
}

user_is_configured() {
  local sought=${1-} user
  (( USERS_LOADED == 1 )) || load_users
  for user in "${USERS[@]}"; do
    [[ $user == "$sought" ]] && return 0
  done
  return 1
}

require_configured_user() {
  local user=${1-}
  validate_user "$user" || exit 1
  user_is_configured "$user" || die "user is not listed in users.conf: $user"
}

public_url() {
  local user=${1-} https_port
  validate_user "$user" || return 1
  (( CONFIG_LOADED == 1 )) || load_config
  https_port=$((10#$CADDY_HTTPS_PORT))
  if (( https_port == 443 )); then
    printf 'https://%s.%s\n' "$user" "$T3_DOMAIN"
  else
    printf 'https://%s.%s:%s\n' "$user" "$T3_DOMAIN" "$CADDY_HTTPS_PORT"
  fi
}

run_cmd() {
  local arg
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    printf '[dry-run]'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi
  "$@"
}

array_contains() {
  local wanted=$1 item
  shift
  for item in "$@"; do
    [[ $item == "$wanted" ]] && return 0
  done
  return 1
}
