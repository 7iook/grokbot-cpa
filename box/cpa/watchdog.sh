#!/usr/bin/env bash
# CPA supervisor. Single instance (flock on .watchdog.lock): safe to launch any number of times, extra copies
# exit at once. Launched at boot by ~/boot-services.sh and relaunched by the Tailscale watchdog if it dies.
#  - CPA runs as our child and we `wait` on it, so a crash is noticed instantly and CPA restarts immediately.
#    Quick repeated crashes back off 1,2,4..60s (reset once CPA has stayed up STABLE_AFTER s).
#    A CPA we did not start ourselves (start.sh / healthcheck) is adopted and polled every TICK s.
#  - CPA alive but not answering HTTP for HEALTH_FAILS checks in a row (every HEALTH_EVERY s) -> killed + restarted.
#    Failures only count once CPA has answered after its start, or START_GRACE s after its start (slow starts under
#    memory pressure took 130s+). With MemAvailable < MEM_GUARD_MB nothing is killed (logged only): killing a CPA
#    that is merely slow because the box is out of memory just restarts the slow start (2026-11-03 15:39-15:41 loop).
#  - child bookkeeping is self-healing: a child already reaped by bash (`wait -n` -> "no such job") or replaced by a
#    CPA started elsewhere (start.sh / healthcheck) is noticed every tick; an adopted CPA gets its real start time.
#  - keeps the Cloudflare tunnel alive, including refreshing it right after the VM is paused/snapshot-restored
#    or when its edge flows go dead.
#  - watches the Tailscale watchdog: relaunches it if it is gone, kills+relaunches it if its heartbeat is stale.
# Every child is started with fd 6 (our lock) closed, so nothing else can keep the lock alive after we die.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
mkdir -p "$LOG_DIR"
exec 6>"$WD_LOCK"; flock -n 6 || exit 0
echo $$ > "$WD_PIDFILE"; rm -f "$WD_STOPPED"
TICK=${TICK:-2}; HEALTH_EVERY=${HEALTH_EVERY:-5}; HEALTH_FAILS=${HEALTH_FAILS:-6}; START_GRACE=${START_GRACE:-90}
STABLE_AFTER=${STABLE_AFTER:-60}; MAX_BACKOFF=${MAX_BACKOFF:-60}; PEER_STALE=${PEER_STALE:-300}
MEM_GUARD_MB=${MEM_GUARD_MB:-1024}
log() { echo "$(TZ=$LOG_TZ date '+%F %T %Z') $*" >> "$LOG_DIR/watchdog.log"; }
uptime_s() { cut -d. -f1 /proc/uptime; }
trap 'log "watchdog stopping"; [ "$(cat "$WD_PIDFILE" 2>/dev/null)" = $$ ] && rm -f "$WD_PIDFILE"; exit 0' TERM INT

child=""; hung_kill=0; started_at=0; backoff=0; next_start=0; fails=0; last_health=0; up_logged=1
quiet_until=0; last_off=""; last_peer=-1000; last_rotate=0; adopted_pid=""
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
mem_avail_mb() { awk '/^MemAvailable:/ { printf "%d", $2 / 1024; f = 1 } END { if (!f) print 999999 }' /proc/meminfo; }
child_gone() { # our child has exited (zombie or already reaped); its pid cannot be reused until we reap it
  local state; kill -0 "$1" 2>/dev/null || return 0
  state=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; state=${state##*) }; [ "${state%% *}" = Z ]
}
proc_started_at() { # $1 pid -> its start time in uptime seconds (same clock as uptime_s); fails if gone
  local st; st=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  st=${st##*) }; set -- $st; [ -n "${20:-}" ] || return 1   # field 22 (starttime) is the 20th after "comm)"
  echo $(( ${20} / CLK_TCK ))
}
sync_child() { # repair stale bookkeeping; runs every tick before the health check
  if [ -n "$child" ] && child_gone "$child"; then
    local st=0; wait "$child" 2>/dev/null; st=$?   # reaps a zombie (real status); 127 if bash already reaped it
    log "CPA child (pid $child) is gone$([ "$st" = 127 ] && echo " (already reaped, status unknown)")"
    cpa_exited "$([ "$st" = 127 ] && echo unknown || echo "$st")"
  fi
  local pid; pid=$(cat "$CPA_PIDFILE" 2>/dev/null)
  if [ -n "$child" ] && [ -n "$pid" ] && [ "$pid" != "$child" ] && cpa_running; then
    log "CPA pidfile now points to pid $pid (not our child $child) - adopting it"; child=""
  fi
  if [ -z "$child" ] && cpa_running && [ "$pid" != "$adopted_pid" ]; then
    adopted_pid=$pid; started_at=$(proc_started_at "$pid") || started_at=$(uptime_s)
    fails=0; up_logged=0; log "adopted CPA pid $pid (started $(( $(uptime_s) - started_at ))s ago)"
  fi
  [ -z "$child" ] && ! cpa_running && adopted_pid=""
}

spawn_cpa() { # start CPA as our child; serialized with start.sh via .cpa.lock
  exec 5>"$CPA_DIR/.cpa.lock"; flock -w 30 5
  if cpa_running; then exec 5>&-; log "CPA already started by someone else (pid $(cat "$CPA_PIDFILE")) - adopting"; return; fi
  local stray; stray=$(pgrep -f "^$CPA_BIN " || true)
  [ -n "$stray" ] && { log "killing stray CPA not tracked by pidfile: $(echo $stray)"; kill $stray 2>/dev/null; sleep 1; }
  cd "$CPA_DIR" || return
  "$CPA_BIN" -config "$CPA_CONFIG" >>"$LOG_DIR/cpa.out" 2>&1 </dev/null 5>&- 6>&- &
  child=$!; echo "$child" > "$CPA_PIDFILE"; exec 5>&-
  started_at=$(uptime_s); fails=0; up_logged=0; adopted_pid=""
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
  # readiness is logged as soon as the port answers; failures only count after that, or after START_GRACE
  if [ "$up_logged" = 0 ] && [ $(( now - started_at )) -lt "$START_GRACE" ]; then
    port_open && http_ok && { log "CPA answering on $CPA_HOST:$CPA_PORT ($(( now - started_at ))s after start)"; up_logged=1; }
    return
  fi
  [ $(( now - last_health )) -ge "$HEALTH_EVERY" ] || return
  last_health=$now
  if http_ok; then
    [ "$up_logged" = 0 ] && { log "CPA answering on $CPA_HOST:$CPA_PORT ($(( now - started_at ))s after start)"; up_logged=1; }
    [ "$fails" -gt 0 ] && log "CPA answering again after $fails failed check(s)"; fails=0
  else
    fails=$((fails + 1)); log "CPA not answering on $CPA_HOST:$CPA_PORT ($fails/$HEALTH_FAILS)"
    local mem; mem=$(mem_avail_mb)
    if [ "$fails" -ge "$HEALTH_FAILS" ] && [ "$mem" -lt "$MEM_GUARD_MB" ]; then
      log "CPA not answering for $fails checks but MemAvailable ${mem}MB < ${MEM_GUARD_MB}MB - not killing it (memory pressure)"; fails=0
    elif [ "$fails" -ge "$HEALTH_FAILS" ]; then
      log "CPA hung (pid $(cat "$CPA_PIDFILE" 2>/dev/null)) - killing it"; hung_kill=1; kill_cpa; fails=0; backoff=0; next_start=0
    fi
  fi
}
# --- resume / public observability (2026-10-26) ---
# One probe. Sets _probe_code and _probe_ms. 2xx-4xx = OK (same as before: Cloudflare
# reached us; 5xx/000/530/524 = broken).
public_probe() {
  local out code secs
  out=$(curl -s -o /dev/null -m 6 -w '%{http_code} %{time_total}' "https://$CF_HOSTNAME/" 2>/dev/null) || out="000 6.000"
  code=${out%% *}; secs=${out##* }
  _probe_code=${code:-000}
  _probe_ms=$(awk -v t="${secs:-0}" 'BEGIN{printf "%d", (t+0)*1000}')
  case "$_probe_code" in 2??|3??|4??) return 0;; *) return 1;; esac
}
# 3 probes (unchanged decision rule). Sets _public_detail like "200/80ms,000/6000ms,530/120ms".
public_ok() {
  local i ok=0 detail=""
  for i in 1 2 3; do
    public_probe && ok=$((ok+1))
    detail="${detail}${detail:+,}${_probe_code}/${_probe_ms}ms"
    [ "$i" -lt 3 ] && sleep 1
  done
  _public_detail=$detail
  [ "$ok" -eq 3 ]
}
# Snapshot at resume time for the log line / JSONL.
resume_diag() {
  local ready="-" stale="no" localcpa="down" age="-"
  if tunnel_running; then
    ready=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$CF_METRICS/ready" 2>/dev/null || echo 000)
    tunnel_conns_stale && stale="yes"
    age=$(file_age "$CF_PIDFILE")
  else
    ready="not_running"; stale="n/a"
  fi
  http_ok && localcpa="up"
  _diag_ready=$ready; _diag_stale=$stale; _diag_local=$localcpa; _diag_age=$age
  echo "ready=$ready stale=$stale local_cpa=$localcpa tunnel_age=${age}s"
}
# Append one JSON object to resume-events.log (best-effort; never fails the watchdog).
resume_event() {
  local payload=$1
  mkdir -p "$LOG_DIR" 2>/dev/null
  printf '%s\n' "$payload" >>"$LOG_DIR/resume-events.log" 2>/dev/null || true
}
# After a restart, poll until public answers (or limit). Logs time-to-recover from resume t0.
wait_public_recover() {
  local t0=$1 limit=${2:-45} started last="-"
  started=$(uptime_s)
  while [ $(( $(uptime_s) - started )) -lt "$limit" ]; do
    if public_probe; then
      log "public recovered in $(( $(uptime_s) - t0 ))s after resume (probe ${_probe_code}/${_probe_ms}ms)"
      return 0
    fi
    last="${_probe_code}/${_probe_ms}ms"
    sleep 2
  done
  public_probe || true
  log "public still failing $(( $(uptime_s) - t0 ))s after resume (last ${_probe_code}/${_probe_ms}ms, earlier=$last)"
  return 1
}
check_tunnel() { # $1 = resume reason (empty if none)
  [ -f "$CF_CONFIG" ] && [ ! -f "$CPA_DIR/.tunnel-disabled" ] || return
  if ! ( flock -n 9 ) 9>"$TUNNEL_LOCK"; then :   # a restart is in progress elsewhere
  elif ! tunnel_running; then
    log "tunnel not running - restarting"; out=$("$CPA_DIR/start-tunnel.sh" 2>&1 6>&-); log "$out"
  elif [ -n "$1" ]; then
    # Observe first, then same decision as before: skip only when edge is fresh AND public is OK.
    local t0 diag stale=0 pub=-1 detail="n/a" why decide_s recover_s
    t0=$(uptime_s)
    diag=$(resume_diag)
    tunnel_conns_stale && stale=1
    if [ -n "$CF_HOSTNAME" ] && [ "$stale" = 0 ]; then
      if public_ok; then pub=1; else pub=0; fi
      detail=${_public_detail:-?}
    elif [ -n "$CF_HOSTNAME" ]; then
      # stale already forces restart; one cheap probe only, for the log
      if public_probe; then pub=1; else pub=0; fi
      detail="${_probe_code}/${_probe_ms}ms"
    fi
    decide_s=$(( $(uptime_s) - t0 ))
    if [ -n "$CF_HOSTNAME" ] && [ "$stale" = 0 ] && [ "$pub" = 1 ]; then
      log "$1 - tunnel still serving publicly, no restart (${diag}; public=[$detail]; decide=${decide_s}s)"
      resume_event "{\"ts\":\"$(TZ=$LOG_TZ date -Iseconds)\",\"event\":\"resume_skip\",\"pause\":\"$1\",\"ready\":\"$_diag_ready\",\"stale\":\"$_diag_stale\",\"local_cpa\":\"$_diag_local\",\"tunnel_age_s\":\"$_diag_age\",\"public\":\"$detail\",\"decide_s\":$decide_s}"
    else
      if [ "$stale" = 1 ] && [ "$pub" = 0 ]; then why="stale+public"
      elif [ "$stale" = 1 ]; then why="stale"
      else why="public"; fi
      log "$1 - refreshing tunnel ($why; ${diag}; public=[$detail]; decide=${decide_s}s)"
      out=$("$CPA_DIR/restart-tunnel.sh" fast 2>&1 6>&-); log "$(echo $out)"
      if [ -n "$CF_HOSTNAME" ]; then
        wait_public_recover "$t0" 45 || true
        recover_s=$(( $(uptime_s) - t0 ))
      else recover_s=$(( $(uptime_s) - t0 )); fi
      resume_event "{\"ts\":\"$(TZ=$LOG_TZ date -Iseconds)\",\"event\":\"resume_refresh\",\"pause\":\"$1\",\"why\":\"$why\",\"ready\":\"$_diag_ready\",\"stale\":\"$_diag_stale\",\"local_cpa\":\"$_diag_local\",\"tunnel_age_s\":\"$_diag_age\",\"public\":\"$detail\",\"decide_s\":$decide_s,\"recover_s\":$recover_s}"
    fi
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

  [ -f "$CPA_DIR/.maintenance" ] || sync_child
  if [ -f "$CPA_DIR/.maintenance" ]; then :
  elif [ -n "$child" ]; then check_health "$now"
  elif cpa_running; then check_health "$now"        # adopted CPA (not our child); started_at set by sync_child
  elif [ "$now" -ge "$next_start" ]; then
    [ "$next_start" = 0 ] && log "CPA not running - starting"; spawn_cpa; next_start=0
  fi

  [ -f "$CPA_DIR/.maintenance" ] || check_tunnel "$resumed"
  check_peer "$now"
  if [ $(( now - last_rotate )) -ge 60 ]; then last_rotate=$now
    for f in watchdog.log cpa.out tunnel.log boot.log resume-events.log; do rotate_log "$LOG_DIR/$f" 10485760; done
  fi

  # sleep one tick, but wake up the instant our CPA child exits
  sleep "$TICK" 6>&- & sl=$!
  if [ -n "$child" ]; then
    done_pid=""; wait -n -p done_pid "$sl" "$child" 2>/dev/null; st=$?
    if [ "${done_pid:-}" = "$child" ]; then cpa_exited "$st"; kill "$sl" 2>/dev/null; wait "$sl" 2>/dev/null
    elif [ -z "${done_pid:-}" ]; then   # wait failed at once (child already reaped -> "no such job", status 127)
      if child_gone "$child"; then
        log "CPA child (pid $child) already reaped - treating it as exited"; cpa_exited unknown
      fi
      wait "$sl" 2>/dev/null           # finish this tick's sleep
    fi
    done_pid=""
  else wait "$sl"; fi
done
