#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$CPA_DIR"; mkdir -p "$LOG_DIR"
exec 9>"$CPA_DIR/.cpa.lock"; flock -w 30 9
if cpa_running; then echo "CPA already running (pid $(cat $CPA_PIDFILE))"; exit 0; fi
# kill stray instance on our port (not tracked by pidfile)
stray=$(pgrep -f "^$CPA_BIN" || true); [ -n "$stray" ] && kill $stray 2>/dev/null && sleep 1
nohup "$CPA_BIN" -config "$CPA_CONFIG" >>"$LOG_DIR/cpa.out" 2>&1 </dev/null 9>&- &
echo $! > "$CPA_PIDFILE"
for i in $(seq 1 30); do port_open && { echo "CPA started (pid $(cat $CPA_PIDFILE)) on $CPA_HOST:$CPA_PORT"; exit 0; }; cpa_running || break; sleep 0.5; done
echo "CPA failed to start; see $LOG_DIR/cpa.out"; exit 1
