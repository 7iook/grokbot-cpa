#!/usr/bin/env bash
# CPA supervisor. Single instance (flock on .watchdog.lock): safe to launch any number of times, extra copies
# exit at once. Launched at boot by /home/box/boot-services.sh and relaunched by the Tailscale watchdog if it dies.
#  - CPA runs as our child and we `wait` on it, so a crash is noticed instantly and CPA restarts immediately.
#    Quick repeated crashes back off 1,2,4..60s (reset once CPA has stayed up STABLE_AFTER s).
#    A CPA we did not start ourselves (start.sh / healthcheck) is adopted and polled every TICK s.
#  - CPA alive but not answering HTTP for HEALTH_FAILS checks in a row (every HEALTH_EVERY s) -> killed + restarted.
#  - keeps the Cloudflare tunnel alive, including refreshing it right after the VM is paused/snapshot-restored
#    or when its edge flows go dead.
#  - watches the Tailscale watchdog: relaunches it if it is gone, kills+relaunches it if its heartbeat is stale.
# Every child is started with fd 6 (our lock) closed, so nothing else can keep the lock alive after we die.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
mkdir -p "$LOG_DIR"
exec 6>"$WD_LOCK"; flock -n 6 || exit 0
echo $$ > "$WD_PIDFILE"; rm -f "$WD_STOPPED"
TICK=${TICK:-2}; HEALTH_EVERY=${HEALTH_EVERY:-5}; HEALTH_FAILS=${HEALTH_FAILS:-3}; START_GRACE=${START_GRACE:-20}
STABLE_AFTER=${STABLE_AFTER:-60}; MAX_BACKOFF=${MAX_BACKOFF:-60}; PEER_STALE=${PEER_STALE:-300}
log() { echo "$(TZ=$LOG_TZ date '+%F %T %Z') $*" >> "$LOG_DIR/watchdog.log"; }
uptime_s() { cut -d. -f1 /proc/uptime; }
trap 'log "watchdog stopping"; [ "$(cat "$WD_PIDFILE" 2>/dev/null)" = $$ ] && rm -f "$WD_PIDFILE"; exit 0' TERM INT

child=""; hung_kill=0; started_at=0; backoff=0; next_start=0; fails=0; last_health=0; up_logged=1
quiet_until=0; last_off=""; last_peer=-1000; last_rotate=0

spawn_cpa() { # start CPA as our child; serialized with start.sh via .cpa.lock
  exec 5>"$CPA_DIR/.cpa.lock"; flock -w 30 5
  if cpa_running; then exec 5>&-; log "CPA already started by someone else (pid $(cat "$CPA_PIDFILE")) - adopting"; return; fi
  local stray; stray=$(pgrep -f "^$CPA_BIN " || true)
  [ -n "$stray" ] && { log "killing stray CPA not tracked by pidfile: $(echo $stray)"; kill $stray 2>/dev/null; sleep 1; }
  cd "$CPA_DIR" || return
  "$CPA_BIN" -config "$CPA_CONFIG" >>"$LOG_DIR/cpa.out" 2>&1 </dev/null 5>&- 6>&- &
  child=$!; echo "$child" > "$CPA_PIDFILE"; exec 5>&-
  started_at=$(uptime_s); fails=0; up_logged=0
  log "CPA started (pid $child)"
}
cpa_exited() { # $1 = exit status of our child
  local ran=$(( $(uptime_s) - started_at ))
  if [ "$ran" -ge "$STABLE_AFTER" ] || [ "$hung_kill" = 1 ]; then backoff=0
  else backoff=$(( backoff ? backoff * 2 : 1 )); [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF; fi
  next_start=$(( $(uptime_s) + backoff ))
  log "CPA (pid $child) exited with status $1 after ${ran}s - restarting$([ "$backoff" -gt 0 ] && echo " in ${backoff}s (backoff: crashed within ${STABLE_AFTER}s)")"
  [ "$(cat "$CPA_PIDFILE" 2>/dev/null)" = "$child" ] && rm -f "$CPA_PIDFILE"
  child=""; hung_kill=0
}
kill_cpa() { # TERM (+CONT: a stopped process must see it), KILL after 3s; our child's exit is then picked up by wait
  local pid; pid=$(cat "$CPA_PIDFILE" 2>/dev/null) || return
  kill -TERM "$pid" 2>/dev/null; kill -CONT "$pid" 2>/dev/null
  local i; for i in $(seq 1 6); do pid_is "$pid" "^$CPA_BIN " || return 0; sleep 0.5; done
  kill -KILL "$pid" 2>/dev/null
}
check_health() {
  local now=$1
  # readiness is logged as soon as the port answers; failures only count after START_GRACE
  if [ "$up_logged" = 0 ] && [ $(( now - started_at )) -lt "$START_GRACE" ]; then
    port_open && http_ok && { log "CPA answering on $CPA_HOST:$CPA_PORT ($(( now - started_at ))s after start)"; up_logged=1; }
    return
  fi
  [ $(( now - started_at )) -ge "$START_GRACE" ] && [ $(( now - last_health )) -ge "$HEALTH_EVERY" ] || return
  last_health=$now
  if http_ok; then
    [ "$up_logged" = 0 ] && { log "CPA answering on $CPA_HOST:$CPA_PORT ($(( now - started_at ))s after start)"; up_logged=1; }
    [ "$fails" -gt 0 ] && log "CPA answering again after $fails failed check(s)"; fails=0
  else
    fails=$((fails + 1)); log "CPA not answering on $CPA_HOST:$CPA_PORT ($fails/$HEALTH_FAILS)"
    if [ "$fails" -ge "$HEALTH_FAILS" ]; then
      log "CPA hung (pid $(cat "$CPA_PIDFILE" 2>/dev/null)) - killing it"; hung_kill=1; kill_cpa; fails=0; backoff=0; next_start=0
    fi
  fi
}
check_tunnel() { # $1 = resume reason (empty if none)
  [ -f "$CF_CONFIG" ] && [ ! -f "$CPA_DIR/.tunnel-disabled" ] || return
  if ! ( flock -n 9 ) 9>"$TUNNEL_LOCK"; then :   # a restart is in progress elsewhere
  elif ! tunnel_running; then
    log "tunnel not running - restarting"; out=$("$CPA_DIR/start-tunnel.sh" 2>&1 6>&-); log "$out"
  elif [ -n "$1" ]; then
    log "$1 - refreshing tunnel connections"; out=$("$CPA_DIR/restart-tunnel.sh" fast 2>&1 6>&-); log "$(echo $out)"
  elif tunnel_conns_stale; then
    log "tunnel edge connection dead (unacked >20s) - restarting"; out=$("$CPA_DIR/restart-tunnel.sh" fast 2>&1 6>&-); log "$(echo $out)"
  fi
}
check_peer() { # the Tailscale watchdog; at most one relaunch per 30s
  local now=$1 why="" age pid
  [ -x "$TS_DIR/ensure-up.sh" ] && [ ! -f "$TS_DIR/.watchdog-stopped" ] && [ $(( now - last_peer )) -ge 30 ] || return
  if ! lock_held "$TS_WD_LOCK"; then why="is not running"
  elif [ "$now" -ge "$quiet_until" ] && age=$(file_age "$TS_WD_HEARTBEAT") && [ "$age" -gt "$PEER_STALE" ]; then
    why="looks hung (heartbeat ${age}s old)"
    pid=$(cat "$TS_WD_PIDFILE" 2>/dev/null); pid_is "$pid" "$TS_DIR/watchdog\.sh" && { kill -KILL "$pid" 2>/dev/null || sudo -n kill -KILL "$pid" 2>/dev/null; }
    sleep 0.5
  fi
  [ -n "$why" ] || return
  last_peer=$now; log "tailscale watchdog $why - relaunching it via ensure-up.sh"
  "${CLEAN_ENV[@]}" setsid -f /bin/bash "$TS_DIR/ensure-up.sh" </dev/null >/dev/null 2>&1 6>&-
}

log "watchdog started (pid $$)"
while true; do
  touch "$WD_HEARTBEAT"; now=$(uptime_s)
  # wall clock jumped vs uptime = VM was paused: peers' heartbeats look old for a moment, so don't judge them yet
  off=$(( $(date +%s) - now )); [ -n "$last_off" ] && [ $(( off - last_off )) -gt 5 ] && quiet_until=$(( now + 20 )); last_off=$off
  resumed=$(vm_resumed) || resumed=""
  [ -n "$resumed" ] && { last_health=$now; fails=0; }   # give CPA a moment after a resume before judging it

  if [ -f "$CPA_DIR/.maintenance" ]; then :
  elif [ -n "$child" ]; then check_health "$now"
  elif cpa_running; then started_at=0; check_health "$now"        # adopted CPA (not our child)
  elif [ "$now" -ge "$next_start" ]; then
    [ "$next_start" = 0 ] && log "CPA not running - starting"; spawn_cpa; next_start=0
  fi

  [ -f "$CPA_DIR/.maintenance" ] || check_tunnel "$resumed"
  check_peer "$now"
  if [ $(( now - last_rotate )) -ge 60 ]; then last_rotate=$now
    for f in watchdog.log cpa.out tunnel.log boot.log; do rotate_log "$LOG_DIR/$f" 10485760; done
  fi

  # sleep one tick, but wake up the instant our CPA child exits
  sleep "$TICK" 6>&- & sl=$!
  if [ -n "$child" ]; then
    wait -n -p done_pid "$sl" "$child"; st=$?
    if [ "${done_pid:-}" = "$child" ]; then cpa_exited "$st"; kill "$sl" 2>/dev/null; wait "$sl" 2>/dev/null; fi
    done_pid=""
  else wait "$sl"; fi
done
