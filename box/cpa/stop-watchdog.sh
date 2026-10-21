#!/usr/bin/env bash
# Stop the CPA watchdog (CPA itself keeps running). Leaves .watchdog-stopped so that neither the boot hook nor
# the Tailscale watchdog relaunches it, including after a box reset; start-watchdog.sh clears it.
# To only pause CPA restarts while the watchdog keeps running, touch $CPA_DIR/.maintenance instead.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
touch "$WD_STOPPED"
pid=$(cat "$WD_PIDFILE" 2>/dev/null)
if pid_is "$pid" "$CPA_DIR/watchdog\.sh"; then kill "$pid"
  for i in $(seq 1 20); do wd_running || break; sleep 0.25; done
  wd_running && echo "watchdog (pid $pid) did not release its lock" || echo "watchdog stopped (will not be relaunched until start-watchdog.sh)"
elif wd_running; then echo "watchdog lock is held but pidfile is stale; not killing blindly"; exit 1
else echo "watchdog not running"; fi
rm -f "$WD_PIDFILE"
