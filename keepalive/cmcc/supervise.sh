#!/usr/bin/env bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# cmcc-cloud-alive WebUI supervisor: single instance (flock), restarts the WebUI if it exits or stops answering.
# Loop tick 5s; 3 consecutive failed health checks -> restart. Failures count only after the WebUI first answered or
# START_GRACE (90s) after start, and nothing is killed while MemAvailable < MEM_GUARD_MB (1024) (2026-11-03). Safe to launch repeatedly (extra copies exit at once).
# PID is empty (never 0) when no child is tracked: `kill -0 0` / `kill -9 0` would signal the whole process group.
APP="$(cd "$(dirname "$0")" && pwd)"
PORT="${CMCC_WEBUI_PORT:-28080}"
LOGDIR="$APP/logs"; mkdir -p "$LOGDIR"
exec 9>"$APP/.supervise.lock"; flock -n 9 || exit 0
log() { echo "$(date '+%F %T %Z') $*" >> "$LOGDIR/supervise.log"; }
PID=""; FAILS=0; STARTED=0; UP=0; START_GRACE=${START_GRACE:-90}; MEM_GUARD_MB=${MEM_GUARD_MB:-1024}
mem_avail_mb() { awk '/^MemAvailable:/ { printf "%d", $2 / 1024; f = 1 } END { if (!f) print 999999 }' /proc/meminfo; }
trap 'log "supervisor stopping"; [ -n "$PID" ] && kill "$PID" 2>/dev/null; exit 0' TERM INT
start() {
  CMCC_WEBUI_HOST=127.0.0.1 CMCC_WEBUI_PORT="$PORT" setsid "$APP/.venv-webui/bin/python" -m cmcc_cloud_alive.webui.app >> "$LOGDIR/webui.log" 2>&1 &
  PID=$!; FAILS=0; UP=0; STARTED=$(cut -d. -f1 /proc/uptime); log "webui started pid=$PID port=$PORT"
}
log "supervisor started (pid $$)"
while true; do
  if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    [ -n "$PID" ] && log "webui pid $PID is gone - restarting"
    start; sleep 4
  elif curl -fsS -m 4 -o /dev/null "http://127.0.0.1:$PORT/"; then FAILS=0; UP=1
  elif [ "$UP" = 0 ] && [ $(( $(cut -d. -f1 /proc/uptime) - STARTED )) -lt "$START_GRACE" ]; then :   # still starting
  elif [ "$(mem_avail_mb)" -lt "$MEM_GUARD_MB" ]; then
    FAILS=$((FAILS+1)); [ "$FAILS" -ge 3 ] && { log "webui not answering x$FAILS but MemAvailable $(mem_avail_mb)MB < ${MEM_GUARD_MB}MB - not killing"; FAILS=0; }
  else
    FAILS=$((FAILS+1))
    if [ "$FAILS" -ge 3 ]; then log "webui not answering x$FAILS - killing pid $PID"; kill -9 "$PID" 2>/dev/null; PID=""; fi
  fi
  sleep 5 & wait $!
done
