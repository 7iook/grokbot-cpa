#!/usr/bin/env bash
# Single-instance Tailscale watchdog (flock). Checks every TICK s (1).
#  - tailscaled process missing (confirmed twice, 2s apart) -> ensure-up.sh. If an ensure-up is already running
#    (boot hook / healthcheck), wait for it instead of launching a no-op one. Restarts that leave tailscaled
#    missing back off 2,4,8..30s.
#  - VM resume detected -> give tailscaled RESUME_CHECK s (5); if it is not Running+Self.Online, or its log shows
#    control long-poll / map-update errors since the resume, restart it right away. (Observed: after a resume
#    tailscaled often never recovers its control connection on its own.)
#  - otherwise: daemon not answering for >= UNANSWER_LIMIT (15s) or not Running/online for >= OFFLINE_LIMIT (20s)
#    -> restart. Never kills a daemon younger than MIN_KILL_AGE (60s, lib.sh): a fresh daemon needs ~40-60s to
#    reach Running here, and killing it earlier only restarts that wait (2026-10-17 07:59-08:01). No two
#    restarts within RESTART_GAP (20s).
#  - watches the CPA watchdog: relaunches it (boot-services.sh) if it is gone, kills+relaunches it if hung.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
exec 8>"$D/.watchdog.lock"; flock -n 8 || exit 0
echo $$ > "$WD_PIDFILE"
OFFLINE_LIMIT=${OFFLINE_LIMIT:-20}; UNANSWER_LIMIT=${UNANSWER_LIMIT:-15}
RESUME_CHECK=${RESUME_CHECK:-5}; RESTART_GAP=${RESTART_GAP:-20}; TICK=${TICK:-1}; PEER_STALE=${PEER_STALE:-300}
CTRL_ERR='long-poll timed out|lite map update error|map response long-poll|PollNetMap: .*(timeout|context deadline)'
wlog() { echo "$(TZ=$LOG_TZ date '+%F %T %Z') $*" >>"$WLOG"; }
run_ensure() {
  if lock_held "$D/.ensure.lock"; then
    wlog "ensure-up already running; waiting for it"; flock -w 100 "$D/.ensure.lock" true 2>/dev/null
    tsd_pids >/dev/null && return 0
  fi
  timeout -k 5 100 /bin/bash "$D/ensure-up.sh" >/dev/null 2>&1 9>&- 8>&-
}
logsize() { stat -c %s "$LOG" 2>/dev/null || echo 0; }
ctrl_errors_since() { tail -c +"$(( $1 + 1 ))" "$LOG" 2>/dev/null | grep -Eq "$CTRL_ERR"; }
last_restart=-1000
restart() { # $1 reason; returns 0 if restarted
  local now; now=$(uptime_s)
  [ $(( now - last_restart )) -lt "$RESTART_GAP" ] && return 1
  [ "$(tsd_min_age)" -lt "$MIN_KILL_AGE" ] && return 1   # young daemon: let it finish connecting
  kill_tsd "$1" "" "$WLOG" || return 1
  wlog "restart: $1"; run_ensure; last_restart=$(uptime_s)
  wlog "after restart: $(health_pair)"; bad_since=""; resume_at=""; return 0
}
check_peer() { # the CPA watchdog; at most one relaunch per 30s
  local now=$1 why="" age pid
  [ -x "$BOOT_SERVICES" ] && [ -d "$CPA_DIR" ] && [ ! -f "$CPA_DIR/.watchdog-stopped" ] && [ $(( now - last_peer )) -ge 30 ] || return
  if ! lock_held "$CPA_WD_LOCK"; then why="is not running"
  elif [ "$now" -ge "$quiet_until" ] && age=$(file_age "$CPA_WD_HEARTBEAT") && [ "$age" -gt "$PEER_STALE" ]; then
    why="looks hung (heartbeat ${age}s old)"
    pid=$(cat "$CPA_WD_PIDFILE" 2>/dev/null); pid_is "$pid" "$CPA_DIR/watchdog\.sh" && kill -KILL "$pid" 2>/dev/null
    sleep 0.5
  fi
  [ -n "$why" ] || return
  last_peer=$now; wlog "CPA watchdog $why - relaunching it via boot-services.sh"
  "${CLEAN_ENV[@]}" setsid -f /bin/bash "$BOOT_SERVICES" </dev/null >/dev/null 2>&1 8>&-
}
bad_since=""; bad_kind=""; resume_at=""; resume_log=0; miss_streak=0
last_peer=-1000; quiet_until=0; last_off=""; last_rotate=0
trap 'wlog "watchdog stopping"; [ "$(cat "$WD_PIDFILE" 2>/dev/null)" = $$ ] && rm -f "$WD_PIDFILE"; exit 0' TERM INT
wlog "watchdog started (pid $$; resume check ${RESUME_CHECK}s, offline ${OFFLINE_LIMIT}s, unanswering ${UNANSWER_LIMIT}s, min kill age ${MIN_KILL_AGE}s)"
while true; do
  touch "$WD_HEARTBEAT"; now=$(uptime_s)
  off=$(( $(date +%s) - now )); [ -n "$last_off" ] && [ $(( off - last_off )) -gt 5 ] && quiet_until=$(( now + 20 )); last_off=$off
  check_peer "$now"
  if [ $(( now - last_rotate )) -ge 60 ]; then last_rotate=$now
    for f in "$LOG" "$WLOG" "$ELOG"; do rotate_log "$f" 10485760; done
  fi
  if detect_resume; then resume_at=$(uptime_s); resume_log=$(logsize); bad_since=""; wlog "VM resume detected; checking tailscaled in ${RESUME_CHECK}s"; fi
  if ! tsd_pids >/dev/null; then
    sleep 2
    if ! tsd_pids >/dev/null; then
      wlog "restart: process missing"; run_ensure; last_restart=$(uptime_s); hp=$(health_pair); wlog "after restart: $hp"
      bad_since=""; resume_at=""
      if tsd_pids >/dev/null; then miss_streak=0; sleep "$TICK" 8>&-
      else miss_streak=$((miss_streak + 1)); b=$(( 1 << (miss_streak < 5 ? miss_streak : 5) )); [ $b -gt 30 ] && b=30
        wlog "tailscaled still missing after restart #$miss_streak; next try in ${b}s"; sleep "$b" 8>&-; fi
      continue
    fi
  fi
  miss_streak=0
  hp=$(health_pair)
  # resume window: one decisive check RESUME_CHECK s after the resume
  if [ -n "$resume_at" ] && [ $(( $(uptime_s) - resume_at )) -ge "$RESUME_CHECK" ]; then
    why=""
    [ "$hp" != "Running true" ] && why="not healthy ${RESUME_CHECK}s after resume ($hp)"
    [ -z "$why" ] && ctrl_errors_since "$resume_log" && why="control long-poll errors after resume ($hp)"
    if [ -z "$why" ]; then wlog "resume check: healthy ($hp)"; resume_at=""
    elif restart "$why"; then sleep "$TICK" 8>&-; continue
    elif [ $(( $(uptime_s) - resume_at )) -ge 120 ]; then resume_at=""   # could not act (young daemon); fall back to normal rules
    fi
  fi
  if [ "$hp" = "Running true" ]; then
    [ -n "$bad_since" ] && wlog "recovered by itself after $(( $(uptime_s) - bad_since ))s ($bad_kind)"
    bad_since=""
  elif [ -z "$resume_at" ]; then
    kind=offline; limit=$OFFLINE_LIMIT; [ "${hp% *}" = none ] && { kind=unanswering; limit=$UNANSWER_LIMIT; }
    if [ -z "$bad_since" ] || [ "$kind" != "$bad_kind" ]; then bad_since=$(uptime_s); bad_kind=$kind
      wlog "observed $kind ($hp, daemon age $(tsd_min_age)s); restarting after ${limit}s (not before age ${MIN_KILL_AGE}s)"; fi
    dur=$(( $(uptime_s) - bad_since ))
    [ "$dur" -ge "$limit" ] && restart "$kind for ${dur}s ($hp)"
  fi
  sleep "$TICK" 8>&-
done
