#!/usr/bin/env bash
# Start the CPA watchdog (detached, clean environment). It is single-instance via flock, so this is idempotent.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
mkdir -p "$LOG_DIR"
if wd_running; then echo "watchdog already running (pid $(cat $WD_PIDFILE 2>/dev/null || echo ?))"; exit 0; fi
rm -f "$WD_STOPPED"
"${CLEAN_ENV[@]}" setsid -f /bin/bash "$CPA_DIR/watchdog.sh" >>"$LOG_DIR/watchdog.log" 2>&1 </dev/null 9>&-
for i in $(seq 1 10); do wd_running && break; sleep 0.3; done
wd_running && echo "watchdog started (pid $(cat $WD_PIDFILE 2>/dev/null || echo ?))" || { echo "watchdog failed to start"; exit 1; }
