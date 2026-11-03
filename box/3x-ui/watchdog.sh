#!/usr/bin/env bash
# 3x-ui supervisor (same pattern as ~/cli-proxy-api/watchdog.sh). Single instance via flock on .watchdog.lock.
# Launched at boot by ~/boot-services.sh and relaunched by the Tailscale watchdog. Opt-out: touch $XUI_DIR/.watchdog-stopped (stop.sh does).
#  - x-ui runs as our child (user box); we `wait` on it, so a crash is restarted at once (backoff 1,2,4..60s
#    for quick repeated crashes, reset after STABLE_AFTER s up).
#  - panel not answering HTTP on 127.0.0.1:$XUI_PANEL_PORT for HEALTH_FAILS checks in a row -> killed + restarted.
#    Failures count only once the panel has answered after a start, or START_GRACE s after it; with MemAvailable <
#    MEM_GUARD_MB nothing is killed (logged only) - a slow start under memory pressure is not a hang (2026-11-03).
#  - x-ui's xray child is killed with it (stray xray from our bin folder is cleaned before every start).
#  - keeps the 3x-ui Cloudflare tunnel (tunnel.sh) alive: restarts it when dead, when /ready fails 3x, when the
#    public panel host returns 5xx/000 3x in a row (probe every 60s), and right after a VM pause/snapshot-restore.
#  - DB backup (sqlite online backup) every BACKUP_EVERY s, keep BACKUP_KEEP copies in backups/.
XUI_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$XUI_ROOT/env.sh"
LOG=$XUI_LOG_FOLDER/watchdog.log; LOCK=$XUI_ROOT/.watchdog.lock; PIDF=$XUI_ROOT/watchdog.pid; XPIDF=$XUI_ROOT/x-ui.pid
STOPPED=$XUI_ROOT/.watchdog-stopped; HB=$XUI_ROOT/watchdog.heartbeat
LOG_TZ=${LOG_TZ:-Asia/Shanghai}
mkdir -p "$XUI_LOG_FOLDER" "$XUI_ROOT/backups"
exec 6>"$LOCK"; flock -n 6 || exit 0
[ -f "$STOPPED" ] && exit 0
echo $$ > "$PIDF"
TICK=${TICK:-2}; HEALTH_EVERY=${HEALTH_EVERY:-5}; HEALTH_FAILS=${HEALTH_FAILS:-6}; START_GRACE=${START_GRACE:-90}; MEM_GUARD_MB=${MEM_GUARD_MB:-1024}
STABLE_AFTER=${STABLE_AFTER:-60}; MAX_BACKOFF=${MAX_BACKOFF:-60}
BACKUP_EVERY=${BACKUP_EVERY:-86400}; BACKUP_KEEP=${BACKUP_KEEP:-7}
log() { echo "$(TZ=$LOG_TZ date '+%F %T %Z') $*" >> "$LOG"; }
up() { cut -d. -f1 /proc/uptime; }
pid_is() { [ -n "$1" ] && { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null | grep -Eq "$2"; }
http_ok() { [ "$(curl -s -m 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$XUI_PANEL_PORT/")" != 000 ]; }
mem_avail_mb() { awk '/^MemAvailable:/ { printf "%d", $2 / 1024; f = 1 } END { if (!f) print 999999 }' /proc/meminfo; }
child_gone() { local st; kill -0 "$1" 2>/dev/null || return 0; st=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; st=${st##*) }; [ "${st%% *}" = Z ]; }
rotate() { local s; s=$(stat -c %s "$1" 2>/dev/null) || return 0; [ "$s" -gt 10485760 ] || return 0; cp -f "$1" "$1.1" && : > "$1"; }
child=""; started_at=0; backoff=0; next_start=0; fails=0; last_health=0; hung=0; up_logged=1
trap 'log "watchdog stopping"; [ -n "$child" ] && kill_xui; [ "$(cat "$PIDF" 2>/dev/null)" = $$ ] && rm -f "$PIDF"; exit 0' TERM INT
kill_strays() { local s; s=$(pgrep -f "^$XUI_BIN( |$)|^$XUI_BIN_FOLDER/xray-linux" | grep -vx "$$" || true)
  [ -n "$s" ] && { log "killing stray x-ui/xray: $(echo $s)"; kill $s 2>/dev/null; sleep 1; kill -9 $s 2>/dev/null; } ; true; }
spawn() {
  kill_strays; cd "$XUI_MAIN_FOLDER" || return
  "$XUI_BIN" run >>"$XUI_LOG_FOLDER/x-ui.out" 2>&1 </dev/null 6>&- &
  child=$!; echo "$child" > "$XPIDF"; started_at=$(up); fails=0; up_logged=0; log "x-ui started (pid $child)"
}
kill_xui() { local p=$child; [ -n "$p" ] || return
  kill -TERM "$p" 2>/dev/null; kill -CONT "$p" 2>/dev/null
  for i in $(seq 1 10); do pid_is "$p" "^$XUI_BIN" || break; sleep 0.5; done
  kill -KILL "$p" 2>/dev/null; pkill -f "^$XUI_BIN_FOLDER/xray-linux" 2>/dev/null; true; }
exited() { local ran=$(( $(up) - started_at ))
  if [ "$ran" -ge "$STABLE_AFTER" ] || [ "$hung" = 1 ]; then backoff=0
  else backoff=$(( backoff ? backoff * 2 : 1 )); [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF; fi
  next_start=$(( $(up) + backoff ))
  log "x-ui (pid $child) exited with status $1 after ${ran}s - restarting$([ "$backoff" -gt 0 ] && echo " in ${backoff}s")"
  pkill -f "^$XUI_BIN_FOLDER/xray-linux" 2>/dev/null; rm -f "$XPIDF"; child=""; hung=0; }
health() { local now=$1
  if [ "$up_logged" = 0 ] && [ $(( now - started_at )) -lt "$START_GRACE" ]; then
    http_ok && { log "x-ui panel answering ($(( now - started_at ))s after start)"; up_logged=1; }; return; fi
  [ $(( now - last_health )) -ge "$HEALTH_EVERY" ] || return
  last_health=$now
  if http_ok; then [ "$up_logged" = 0 ] && { log "x-ui panel answering"; up_logged=1; }
    [ "$fails" -gt 0 ] && log "x-ui answering again after $fails failed check(s)"; fails=0
  else fails=$((fails+1)); log "x-ui panel not answering ($fails/$HEALTH_FAILS)"
    if [ "$fails" -ge "$HEALTH_FAILS" ] && [ "$(mem_avail_mb)" -lt "$MEM_GUARD_MB" ]; then
      log "x-ui not answering for $fails checks but MemAvailable $(mem_avail_mb)MB < ${MEM_GUARD_MB}MB - not killing it (memory pressure)"; fails=0
    elif [ "$fails" -ge "$HEALTH_FAILS" ]; then log "x-ui hung - killing it"; hung=1; kill_xui; fails=0; backoff=0; next_start=0; fi
  fi; }
backup_db() {
  local db=$XUI_DB_FOLDER/x-ui.db out; [ -s "$db" ] || return 0
  out=$XUI_ROOT/backups/x-ui.db.$(TZ=$LOG_TZ date +%Y%m%d-%H%M%S)
  if python3 -c 'import sqlite3,sys; s=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()' "$db" "$out" 2>>"$LOG"; then
    chmod 600 "$out"; log "db backup -> ${out##*/}"
  else rm -f "$out"; log "db backup FAILED"; fi
  ls -1t "$XUI_ROOT"/backups/x-ui.db.* 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -f; }
TUN_EVERY=${TUN_EVERY:-10}; PUB_EVERY=${PUB_EVERY:-60}; last_tun=0; last_pub=0; tun_fails=0; pub_fails=0; prev_off=""
tun() { "$XUI_ROOT/tunnel.sh" "$@" 2>&1 6>&- | tr '\n' ' '; }
pub_ok() { local c; [ -n "$XUI_CF_HOSTNAME" ] || return 0; c=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "https://$XUI_CF_HOSTNAME/" 2>/dev/null); case "$c" in 2??|3??|4??) return 0;; *) return 1;; esac; }
check_tunnel() { local now=$1 off
  [ -f "$XUI_CF_CONFIG" ] && [ ! -f "$XUI_ROOT/.tunnel-disabled" ] || return 0
  off=$(( $(date +%s) - now ))
  if [ -n "$prev_off" ] && [ $(( off - prev_off )) -gt 10 ]; then
    log "VM was paused ~$(( off - prev_off ))s - checking tunnel"; prev_off=$off
    if ! pub_ok || ! pub_ok; then log "public check failed after resume - restarting tunnel: $(tun restart 4)"; pub_fails=0; tun_fails=0; fi
    last_pub=$now; return 0
  fi; prev_off=$off
  [ $(( now - last_tun )) -ge "$TUN_EVERY" ] || return 0; last_tun=$now
  if ! "$XUI_ROOT/tunnel.sh" status 2>/dev/null | grep -q "tunnel running"; then log "tunnel not running - starting: $(tun start)"; tun_fails=0; return 0; fi
  if curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$XUI_CF_METRICS/ready" | grep -q 200; then tun_fails=0
  else tun_fails=$((tun_fails+1)); log "tunnel /ready failed ($tun_fails/3)"
    [ "$tun_fails" -ge 3 ] && { log "tunnel not ready - restarting: $(tun restart 4)"; tun_fails=0; }; fi
  if [ $(( now - last_pub )) -ge "$PUB_EVERY" ] && [ "$up_logged" = 1 ]; then last_pub=$now
    if pub_ok; then [ "$pub_fails" -gt 0 ] && log "public $XUI_CF_HOSTNAME ok again"; pub_fails=0
    else pub_fails=$((pub_fails+1)); log "public $XUI_CF_HOSTNAME failing ($pub_fails/3)"
      [ "$pub_fails" -ge 3 ] && { log "public failing - restarting tunnel: $(tun restart 4)"; pub_fails=0; }; fi
  fi; }
last_backup_age() { local f; f=$(ls -1t "$XUI_ROOT"/backups/x-ui.db.* 2>/dev/null | head -1); [ -n "$f" ] || { echo 999999999; return; }; echo $(( $(date +%s) - $(stat -c %Y "$f") )); }
log "watchdog started (pid $$)"
while :; do
  [ -f "$STOPPED" ] && { log ".watchdog-stopped present - exiting"; kill_xui; tun stop >/dev/null; rm -f "$PIDF"; exit 0; }
  now=$(up); touch "$HB"
  if [ -z "$child" ] && [ "$now" -ge "$next_start" ]; then spawn; fi
  if [ -n "$child" ]; then
    if child_gone "$child"; then wait "$child" 2>/dev/null; exited $?
    else health "$now"; fi
  fi
  check_tunnel "$now"
  [ "$(last_backup_age)" -ge "$BACKUP_EVERY" ] && [ -n "$child" ] && [ "$up_logged" = 1 ] && backup_db
  rotate "$LOG"; rotate "$XUI_LOG_FOLDER/x-ui.out"; rotate "$XUI_LOG_FOLDER/tunnel.log"
  sleep "$TICK" & wait $! 2>/dev/null
done
