#!/usr/bin/env bash
# Start the watchdog loop in the background (no-op if already running).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if alive watchdog.pid; then echo "Watchdog already running (pid $(cat watchdog.pid))"; exit 0; fi
nohup "$DIR/watchdog.sh" >>"$DIR/logs/watchdog-loop.log" 2>&1 </dev/null &
echo $! > "$DIR/watchdog.pid"
sleep 1
if alive watchdog.pid; then echo "Watchdog started (pid $(cat watchdog.pid)), log: $DIR/logs/watchdog.log"
else echo "Watchdog failed to start; see logs/watchdog-loop.log" >&2; exit 1; fi
