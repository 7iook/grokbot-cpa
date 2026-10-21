#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ -n "${TUNNEL_LOCK_HELD:-}" ] || { exec 9>"$TUNNEL_LOCK"; flock -w 40 9; }
waits=20; [ -n "${TUNNEL_STOP_FAST:-}" ] && waits=4   # x0.5s
if tunnel_running; then pid=$(cat "$CF_PIDFILE"); kill "$pid"
  for i in $(seq 1 $waits); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid"; echo "tunnel stopped"
else echo "tunnel not running"; fi
rm -f "$CF_PIDFILE"
