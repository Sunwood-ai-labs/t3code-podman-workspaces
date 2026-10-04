#!/bin/sh
set -eu

export HOME=/home/dev
export T3CODE_HOME=/data/t3

: "${T3_PORT:=3773}"

# T3 Code keeps the UI theme in the browser's localStorage. Seed defaults so
# each workspace is visually distinct; whatever the user picks later wins.
seed_default() {
    case "$2" in
        '') ;;
        *[!a-z0-9-]*) echo "Ignoring invalid UI default for $1: $2" >&2 ;;
        *) seed="${seed}localStorage.getItem('$1')||localStorage.setItem('$1','$2');" ;;
    esac
}
index_html="$(find /usr/local/lib/node_modules/t3 -path '*/client/index.html' | head -n 1)"
if [ -n "${index_html}" ] && [ -f "${index_html}.orig" ]; then
    seed=""
    seed_default t3code:theme "${T3_DEFAULT_THEME:-}"
    seed_default t3code:theme-appearance-mode "${T3_DEFAULT_APPEARANCE:-}"
    if [ -n "${seed}" ]; then
        # A cosmetic default must never stop the server from starting.
        sed "s#<head>#<head><script>try{${seed}}catch(e){}</script>#" "${index_html}.orig" > "${index_html}" \
            || cat "${index_html}.orig" > "${index_html}"
    else
        cat "${index_html}.orig" > "${index_html}"
    fi
fi

# The npm launcher runs the native server as a child process. Forward stop signals
# to the whole process group so both the launcher and server exit promptly.
exec tini -g -- t3 serve \
    --mode web \
    --host 0.0.0.0 \
    --port "$T3_PORT" \
    --base-dir /data/t3 \
    --auto-bootstrap-project-from-cwd /workspace
