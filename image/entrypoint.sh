#!/bin/sh
set -eu

export HOME=/home/dev
export T3CODE_HOME=/data/t3

: "${T3_PORT:=3773}"

# The npm launcher runs the native server as a child process. Forward stop signals
# to the whole process group so both the launcher and server exit promptly.
exec tini -g -- t3 serve \
    --mode web \
    --host 0.0.0.0 \
    --port "$T3_PORT" \
    --base-dir /data/t3 \
    --auto-bootstrap-project-from-cwd /workspace
