#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    printf 'Missing shared configuration: %s\n' "${CONFIG_FILE}" >&2
    exit 1
fi

# config.env is a repository-owned shell-compatible key/value file.
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

: "${T3_IMAGE:?T3_IMAGE must be set in config.env}"
: "${T3_VERSION:?T3_VERSION must be set in config.env}"

NODE_VERSION="${NODE_VERSION:-24.15.0}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.289}"
CODEX_VERSION="${CODEX_VERSION:-0.160.0}"

podman_command=(podman)
if [[ -n "${PODMAN_CONNECTION:-}" ]]; then
    podman_command+=(--connection "${PODMAN_CONNECTION}")
fi

exec "${podman_command[@]}" build \
    --file "${REPO_ROOT}/image/Containerfile" \
    --tag "${T3_IMAGE}" \
    --build-arg "NODE_VERSION=${NODE_VERSION}" \
    --build-arg "T3_VERSION=${T3_VERSION}" \
    --build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
    --build-arg "CODEX_VERSION=${CODEX_VERSION}" \
    "${REPO_ROOT}"
