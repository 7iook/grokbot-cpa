#!/usr/bin/env bash
# Idempotent: make sure tailscaled (under sudo, files only in $TS_DIR) is running and cpa-box is online.
# Single instance: if another ensure-up is already running, exit immediately (it is doing the work).
# Bounded: the whole run (while holding the lock) is capped at ENSURE_CAP s (default 90); every CLI call has a timeout.
# Never prints the auth key or state contents. Never runs `up` while BackendState=Running.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROXY=127.0.0.1:1055; SERVE_PORT=8317; SERVE_TARGET=tcp://127.0.0.1:8317
ENSURE_CAP=${ENSURE_CAP:-90}
log() { echo "$(TZ=$LOG_TZ date '+%F %T %Z') [$$] $*" >>"$ELOG"; }

# 1. watchdog (flock inside guarantees a single instance)
"${CLEAN_ENV[@]}" setsid -f /bin/bash "$D/watchdog.sh" >/dev/null 2>&1 </dev/null 9>&- 8>&-

exec 9>"$D/.ensure.lock"; flock -n 9 || exit 0
START=$(uptime_s); DEADLINE=$((START + ENSURE_CAP - 5))
left() { echo $(( DEADLINE - $(uptime_s) )); }
# hard cap: if anything still hangs, kill this run (and its children) so the lock is released
( sleep "$ENSURE_CAP"; kill -0 $$ 2>/dev/null && { echo "$(TZ=$LOG_TZ date '+%F %T %Z') [$$] hard cap ${ENSURE_CAP}s hit; aborting run" >>"$ELOG"; pkill -KILL -P $$; kill -KILL $$; } ) 9>&- >/dev/null 2>&1 &
CAPPID=$!; trap 'pkill -P $CAPPID 2>/dev/null; kill $CAPPID 2>/dev/null' EXIT

start_tsd() { # $1 = kernel|userspace
  local args=(--state="$STATE" --socket="$SOCK" --port=41641)
  [ "$1" = userspace ] && args+=(--tun=userspace-networking --socks5-server="$PROXY" --outbound-http-proxy-listen="$PROXY")
  spawn_tsd "${args[@]}"
  local i; for i in $(seq 1 30); do sleep 0.5; [ "$(left)" -le 0 ] && break
    [ -S "$SOCK" ] && [ "$(bstate)" != none ] && return 0; [ $i -gt 6 ] && ! tsd_pids >/dev/null && return 1; done
  tsd_pids >/dev/null
}

attempt() { # returns 0 healthy, 1 failed hard, 2 wants a restart (reason in $WHY)
  WHY=""
  # 2. start tailscaled if needed
  if ! tsd_pids >/dev/null; then
    reap_strays
    local ssz mode; ssz=$(sudo -n stat -c %s "$STATE" 2>/dev/null || echo 0)
    if [ "$ssz" -lt 1000 ] && [ -s "$BACKUP" ]; then
      sudo -n install -m 600 -o root -g root "$BACKUP" "$STATE"; log "restored state from backup (state was ${ssz} bytes)"
    fi
    mode=userspace; [ -c /dev/net/tun ] && [ ! -f "$D/force-userspace" ] && ! pgrep -x tailscaled >/dev/null && mode=kernel   # another (system) tailscaled owns the TUN -> userspace
    if start_tsd $mode; then log "tailscaled started ($mode)"
    elif [ $mode = kernel ] && [ "$(left)" -gt 15 ]; then
      log "kernel TUN start failed; falling back to userspace"; kill_tsd "kernel start failed" force "$ELOG"
      start_tsd userspace && log "tailscaled started (userspace)" || { log "tailscaled failed to start"; return 1; }
    else log "tailscaled failed to start"; return 1; fi
  fi

  # 3. wait for the daemon to answer / reach a stable state (up to ~20s)
  local st i t0; st=$(bstate); t0=$(uptime_s)
  while [ $(( $(uptime_s) - t0 )) -lt 20 ] && [ "$(left)" -gt 0 ]; do
    case "$st" in Running|NeedsLogin|Stopped|NeedsMachineAuth) break;; esac
    tsd_pids >/dev/null || break
    sleep 1; st=$(bstate)
  done
  if ! tsd_pids >/dev/null; then WHY="tailscaled exited (state=$st)"; return 2; fi
  case "$st" in
    Running) if [ "${TS_SSH:-1}" = 1 ]; then [ "$(ts debug prefs 2>/dev/null | jq -r '.RunSSH' 2>/dev/null)" = true ] || ts set --ssh >/dev/null 2>&1; fi ;;
    NeedsLogin|Stopped|NeedsMachineAuth)
      log "BackendState=$st -> tailscale up"
      sudo -n timeout -k 2 25 "$TS" --socket="$SOCK" up --auth-key="file:$KEY" --hostname="$HOST" --ssh="$([ "${TS_SSH:-1}" = 1 ] && echo true || echo false)" --accept-dns=false 2>&1 \
        | grep -v -i 'auth' >>"$ELOG" ;;
    none) # process exists but does not answer
      if [ "$(tsd_min_age)" -ge "$MIN_KILL_AGE" ]; then WHY="tailscaled not answering"; return 2; fi
      log "tailscaled not answering yet (young daemon), leaving it alone"; return 1 ;;
    *) log "BackendState=$st after 20s; not running up (only for NeedsLogin/Stopped/NeedsMachineAuth)" ;;
  esac

  # 4. health: Running + Self.Online, up to 30s (bounded by the run cap). Sustained "offline" is the watchdog's job.
  local ok=0 hp="none false"; t0=$(uptime_s)
  while [ $(( $(uptime_s) - t0 )) -lt 30 ] && [ "$(left)" -gt 0 ]; do
    hp=$(health_pair); [ "$hp" = "Running true" ] && { ok=1; break; }; sleep 1; done
  if [ $ok = 0 ]; then
    if ! tsd_pids >/dev/null; then WHY="tailscaled exited"; return 2; fi
    if [ "${hp% *}" = none ] && [ "$(tsd_min_age)" -ge "$MIN_KILL_AGE" ]; then WHY="tailscaled not answering"; return 2; fi
    log "not Running/online yet ($hp); leaving it to the watchdog"
  fi

  # 5. serve 8317 on tailnet, backup state
  if [ "${hp% *}" = Running ] && [ "$(left)" -gt 10 ]; then
    ts serve status 2>/dev/null | grep -q ":$SERVE_PORT" || { ts serve --bg --tcp "$SERVE_PORT" "$SERVE_TARGET" >>"$ELOG" 2>&1 && log "serve $SERVE_PORT applied"; }
  fi
  local ssz; ssz=$(sudo -n stat -c %s "$STATE" 2>/dev/null || echo 0)
  if [ "$ssz" -ge 1000 ] && ! sudo -n cmp -s "$STATE" "$BACKUP"; then
    sudo -n install -m 600 -o box -g box "$STATE" "$BACKUP" && log "state backed up"
  fi
  return 0
}

detect_resume
attempt; rc=$?
if [ $rc = 2 ]; then   # retry once (while still holding the lock), only if time is left
  log "restarting tailscaled: $WHY"
  kill_tsd "$WHY" "" "$ELOG"
  if [ "$(left)" -gt 15 ]; then attempt; rc=$?; fi
  [ $rc = 0 ] || log "still unhealthy after retry (${WHY:-rc=$rc}); giving up"
fi
el=$(( $(uptime_s) - START )); { [ $rc != 0 ] || [ $el -ge 10 ]; } && log "done rc=$rc in ${el}s"
exit $rc
