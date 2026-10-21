#!/usr/bin/env bash
# Checks CPA (process, port, authenticated /v1/models) and the Cloudflare tunnel
# (process, registered connection, public /v1/models). Self-heals. Never prints secrets.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
KEY_FILE=$CPA_DIR/secrets/client-api-key
TUNNEL_ON=0; [ -f "$CF_CONFIG" ] && [ ! -f "$CPA_DIR/.tunnel-disabled" ] && TUNNEL_ON=1
models_req() { # $1=url -> sets CODE, MODELS
  local t; t=$(mktemp)
  CODE=$(curl -s -o "$t" -w '%{http_code}' -m 15 -H "Authorization: Bearer $(cat "$KEY_FILE")" "$1")
  MODELS=$(jq -r '(.data // []) | length' "$t" 2>/dev/null); rm -f "$t"
}
check_cpa() {
  cpa_running || { echo "cpa process: DOWN"; return 1; }; echo "cpa process: up (pid $(cat $CPA_PIDFILE))"
  port_open || { echo "cpa port $CPA_PORT: closed"; return 1; }; echo "cpa port $CPA_PORT: open"
  models_req "http://$CPA_HOST:$CPA_PORT/v1/models"
  [ "$CODE" = 200 ] || { echo "local /v1/models: HTTP $CODE"; return 1; }
  echo "local /v1/models: HTTP 200 ($MODELS models)"; LOCAL_MODELS=$MODELS
}
check_tunnel() {
  ( flock -w 60 9 ) 9>"$TUNNEL_LOCK"   # let any in-progress (watchdog) restart finish first
  local w; for w in 1 2 3 4 5; do tunnel_running && break; sleep 2; done
  tunnel_running || { echo "tunnel process: DOWN"; return 1; }; echo "tunnel process: up (pid $(cat $CF_PIDFILE))"
  local i; for i in 1 2 3 4 5 6; do tunnel_ready && break; sleep 2; done
  tunnel_ready || { echo "tunnel connections: none registered"; return 1; }; echo "tunnel connections: registered"
  for i in 1 2 3; do models_req "https://$CF_HOSTNAME/v1/models"; [ "$CODE" = 200 ] && break; sleep 3; done
  case "$CODE" in
    200) echo "public https://$CF_HOSTNAME/v1/models: HTTP 200";;
    401) echo "public https://$CF_HOSTNAME/v1/models: HTTP 401 (reachable, key rejected)";;
    *)   echo "public https://$CF_HOSTNAME/v1/models: HTTP $CODE"; return 1;;
  esac
}
fixed=""; failed=""
wd_running || { "$CPA_DIR/start-watchdog.sh" >/dev/null 2>&1 && fixed="$fixed watchdog"; }
# The box gets paused/snapshot-restored between runs, which silently kills the tunnel's edge connections.
# If that just happened, refresh the connectors first (expected maintenance, not reported as a fix).
if [ $TUNNEL_ON = 1 ] && resumed=$(vm_resumed); then
  "$CPA_DIR/restart-tunnel.sh" fast >/dev/null 2>&1; echo "tunnel: refreshed after resume ($resumed)"
fi
if ! check_cpa; then
  echo "self-heal: restarting CPA"; "$CPA_DIR/stop.sh" >/dev/null 2>&1; "$CPA_DIR/start.sh" >/dev/null 2>&1; sleep 2
  if check_cpa; then fixed="$fixed cpa"; else failed="$failed cpa"; fi
fi
if [ $TUNNEL_ON = 1 ] && [ -z "$failed" ]; then
  if ! check_tunnel; then
    echo "self-heal: restarting tunnel"; "$CPA_DIR/restart-tunnel.sh" fast >/dev/null 2>&1; sleep 3
    if check_tunnel; then fixed="$fixed tunnel"; else failed="$failed tunnel"; fi
  fi
elif [ $TUNNEL_ON = 0 ]; then echo "tunnel: not configured/disabled (skipped)"; fi
# tailscale: informational only, never affects RESULT/exit code
if [ -x ${TS_DIR:-$HOME/tailscale}/ensure-up.sh ]; then
  timeout 150 /bin/bash ${TS_DIR:-$HOME/tailscale}/ensure-up.sh >/dev/null 2>&1 || true
  tsst=$(sudo -n ${TS_DIR:-$HOME/tailscale}/tailscale --socket=${TS_DIR:-$HOME/tailscale}/tailscaled.sock status --json 2>/dev/null | jq -r '"\(.BackendState) \(.TailscaleIPs[0] // "-") \(.Self.DNSName // "-" | rtrimstr("."))"' 2>/dev/null)
  echo "tailscale (info): ${tsst:-not running}"
fi
tun=""; [ $TUNNEL_ON = 1 ] && tun=", tunnel https://$CF_HOSTNAME up"
if [ -n "$failed" ]; then echo "RESULT: FAILED -${failed} unhealthy after restart; see $LOG_DIR/"; exit 2; fi
if [ -n "$fixed" ]; then echo "RESULT: FIXED - restarted:${fixed}; ${LOCAL_MODELS:-0} models${tun}"; exit 0; fi
echo "RESULT: OK - CPA healthy, ${LOCAL_MODELS:-0} models${tun}"
