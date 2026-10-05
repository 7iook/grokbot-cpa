#!/usr/bin/env bash
# Run keepalive.sh every 10 minutes in the background (no-op if already running).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if alive keepalive.pid; then echo "Keepalive already running (pid $(cat keepalive.pid))"; exit 0; fi
nohup bash -c 'while true; do "$1/keepalive.sh"; sleep 600; done' keepalive-loop "$DIR" >>"$DIR/logs/keepalive-loop.log" 2>&1 </dev/null &
echo $! > "$DIR/keepalive.pid"
echo "Keepalive loop started (pid $(cat keepalive.pid)), log: $DIR/logs/keepalive.log"
