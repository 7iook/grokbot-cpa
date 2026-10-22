#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if cpa_running; then pid=$(cat "$CPA_PIDFILE"); kill "$pid"
  for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid"; echo "CPA stopped"
else echo "CPA not running"; fi
# only remove the pidfile if it still names the process we stopped (the watchdog may already have restarted CPA)
[ "$(cat "$CPA_PIDFILE" 2>/dev/null)" = "${pid:-x}" ] || [ -z "${pid:-}" ] && rm -f "$CPA_PIDFILE"
