#!/usr/bin/env bash
# Watchdog loop (every 15s): keeps CLIProxyAPI, the tunnel connector(s) and the keepalive loop up.
# - CLIProxyAPI process gone -> start it; local port not answering 2 checks in a row -> restart it.
# - Connector N process gone -> start it (starting never drops a live connection).
#   /ready not 200 or ha_connections < MIN_CONNS for 2 checks in a row (~30s) -> restart only that one.
# - Unhealthy-connector restarts are staggered: at least GAP_ANY (60s) between any two connector
#   restarts, and a connector is not restarted again within GAP_SELF (120s) of its own restart.
# - Public URL is checked every 15s (PUBLIC_EVERY=1). A 530 means no connector is serving at all,
#   so ALL connectors are restarted at once (nothing left to protect; in quick mode that is the
#   single connector), at most every PUB_GAP (30s). 2 other failures in a row restart the least
#   healthy connector (fewest connections; tie -> the one restarted longest ago), or the next one
#   if that is still in cooldown.
# Only touches processes recorded in this directory's pid files.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
LOG="$DIR/logs/watchdog.log"
INTERVAL="${WATCHDOG_INTERVAL:-15}"; PUBLIC_EVERY=1; GAP_ANY=60; GAP_SELF=120; PUB_GAP=30
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
local_fail=0; public_fail=0; tick=0; last_any_restart=0; last_pub_restart=0
declare -A bad=() last_restart=() conns=()
for n in $(connectors); do bad[$n]=0; last_restart[$n]=0; conns[$n]=0; done

restart_connector() { # n reason
  local n="$1" now; now=$(date +%s)
  log "restarting connector $n ($2)"
  "$DIR/stop-tunnel.sh" "$n" >> "$LOG" 2>&1; sleep 1; "$DIR/start-tunnel.sh" "$n" >> "$LOG" 2>&1
  last_restart[$n]=$now; last_any_restart=$now; bad[$n]=0
}
can_restart() { local now; now=$(date +%s); (( now - last_any_restart >= GAP_ANY && now - ${last_restart[$1]} >= GAP_SELF )); }

log "watchdog started (pid $$), mode=$TUNNEL_MODE connectors=$CONNECTORS"
while true; do
  tick=$((tick + 1))
  # --- CLIProxyAPI
  if ! alive cli-proxy-api.pid; then
    log "CLIProxyAPI not running, starting"; "$DIR/start.sh" >> "$LOG" 2>&1; local_fail=0
  else
    code="$(http_code "$LOCAL_URL/" 10)"
    if [[ "$code" == 200 ]]; then local_fail=0; else
      local_fail=$((local_fail + 1)); log "CLIProxyAPI local check failed ($code), streak $local_fail"
      if (( local_fail >= 2 )); then
        log "CLIProxyAPI unresponsive, restarting"; "$DIR/stop.sh" >> "$LOG" 2>&1; sleep 1; "$DIR/start.sh" >> "$LOG" 2>&1; local_fail=0
      fi
    fi
  fi
  # --- Tunnel connectors
  for n in $(connectors); do
    if ! alive "tunnel$n.pid"; then
      log "connector $n not running, starting"; "$DIR/start-tunnel.sh" "$n" >> "$LOG" 2>&1
      now=$(date +%s); last_restart[$n]=$now; last_any_restart=$now; bad[$n]=0
      continue
    fi
    now=$(date +%s)
    (( now - ${last_restart[$n]} < 20 )) && continue   # still registering
    if probe_connector "$n"; then
      conns[$n]=$CONNS
      (( ${bad[$n]} > 0 )) && log "connector $n healthy again ($CONNS connections)"
      bad[$n]=0
    else
      conns[$n]=$CONNS; bad[$n]=$((${bad[$n]} + 1))
      log "connector $n unhealthy (ready=$READY, $CONNS connections), streak ${bad[$n]}"
      if (( ${bad[$n]} >= 2 )) && can_restart "$n"; then restart_connector "$n" "unhealthy ${bad[$n]} checks"; fi
    fi
  done
  # --- Public fallback check
  URL="$(public_url)"
  if [[ -n "$URL" && $local_fail -eq 0 ]] && (( CONNECTORS > 0 )) && (( tick % PUBLIC_EVERY == 0 || public_fail > 0 )); then
    pcode="$(http_code "$URL/" 15)"
    if [[ "$pcode" == 200 ]]; then
      (( public_fail > 0 )) && log "public URL back to 200 after $public_fail failed checks"
      public_fail=0
    else
      public_fail=$((public_fail + 1)); log "public check failed ($pcode), streak $public_fail"
      now=$(date +%s)
      if [[ "$pcode" == 530 ]]; then
        if (( now - last_pub_restart >= PUB_GAP )); then
          log "public 530: no connector serving, restarting all connectors"
          for n in $(connectors); do
            restart_connector "$n" "public 530"
          done
          last_pub_restart=$now
        fi
      elif (( public_fail >= 2 )); then
        order="$(for n in $(connectors); do probe_connector "$n"; echo "$CONNS ${last_restart[$n]} $n"; done | sort -k1,1n -k2,2n | awk '{print $3}')"
        for n in $order; do
          if can_restart "$n"; then restart_connector "$n" "public $pcode, least healthy available"; public_fail=0; break; fi
        done
      fi
    fi
  fi
  # --- Keepalive (only meaningful with a public URL)
  if (( CONNECTORS > 0 )) && ! alive keepalive.pid; then
    log "keepalive not running, starting"; "$DIR/start-keepalive.sh" >> "$LOG" 2>&1
  fi
  sleep "$INTERVAL"
done
