#!/bin/sh
set -eu

export HOME=/home/dev
export T3CODE_HOME=/data/t3

: "${T3_PORT:=3773}"

# T3 Code keeps the UI theme in the browser's localStorage. Seed a default so
# each workspace is visually distinct; a theme the user picks later wins.
index_html="$(find /usr/local/lib/node_modules/t3 -path '*/client/index.html' | head -n 1)"
if [ -n "${index_html}" ] && [ -f "${index_html}.orig" ]; then
    case "${T3_DEFAULT_THEME:-}" in
        '')
            cat "${index_html}.orig" > "${index_html}"
            ;;
        *[!a-z0-9-]*)
            echo "Ignoring invalid T3_DEFAULT_THEME: ${T3_DEFAULT_THEME}" >&2
            cat "${index_html}.orig" > "${index_html}"
            ;;
        *)
            seed="<script>try{localStorage.getItem('t3code:theme')||localStorage.setItem('t3code:theme','${T3_DEFAULT_THEME}')}catch(e){}</script>"
            # A cosmetic default must never stop the server from starting.
            sed "s#<head>#<head>${seed}#" "${index_html}.orig" > "${index_html}" \
                || cat "${index_html}.orig" > "${index_html}"
            ;;
    esac
fi

# The npm launcher runs the native server as a child process. Forward stop signals
# to the whole process group so both the launcher and server exit promptly.
exec tini -g -- t3 serve \
    --mode web \
    --host 0.0.0.0 \
    --port "$T3_PORT" \
    --base-dir /data/t3 \
    --auto-bootstrap-project-from-cwd /workspace
