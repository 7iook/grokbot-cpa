#!/usr/bin/env bash
# Start Cloudflare tunnel connector(s) in the background.
# Usage: start-tunnel.sh [N|all]   (default: all)
#   TUNNEL_MODE=named : CONNECTORS (default 2) connectors share one tunnel token (.tunnel-token).
#   TUNNEL_MODE=quick : 1 connector, random https://*.trycloudflare.com URL, written to PUBLIC_URL.txt.
#   TUNNEL_MODE=none  : nothing to do.
# Each connector N has its own pid file (tunnelN.pid), log (logs/tunnelN.log) and metrics port
# (127.0.0.1:METRICS_BASE+N, exposes /ready and /metrics).
# HOSTS_WORKAROUND=1 (set by install.sh only when DNS returns fake IPs in 198.18.0.0/15): the connector
# runs in a user+mount namespace with a private /etc/hosts that maps region1/region2.v2.argotunnel.com
# to several real edge IPs. cloudflared resolves the SRV targets with net.LookupIP, which returns
# every hosts line for a name, so several IPs per region allow 4 HA connections per connector.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ "$TUNNEL_MODE" == none ]] && { echo "TUNNEL_MODE=none: no tunnel to start"; exit 0; }
CF="$DIR/cloudflared"
[[ -x "$CF" ]] || { echo "ERROR: $CF not found; run install.sh" >&2; exit 1; }
if [[ "$TUNNEL_MODE" == named && ! -s "$DIR/.tunnel-token" ]]; then
  echo "ERROR: $DIR/.tunnel-token is missing; run set-tunnel-token.sh first" >&2; exit 1
fi

start_one() {
  local n="$1" pf="tunnel$1.pid" hosts="$DIR/.tunnel-hosts$1" log="$DIR/logs/tunnel$1.log"
  local port r1 r2 ip off url old
  port="$(metrics_port "$n")"
  if alive "$pf"; then echo "Connector $n already running (pid $(cat "$DIR/$pf"))"; return 0; fi
  local args=(tunnel --no-autoupdate --protocol "$TUNNEL_PROTOCOL" --edge-ip-version 4 --metrics "127.0.0.1:$port")
  if [[ "$TUNNEL_MODE" == named ]]; then args+=(run --token-file "$DIR/.tunnel-token")   # token never on argv
  else args+=(--url "$LOCAL_URL"); fi
  off="$(stat -c %s "$log" 2>/dev/null || echo 0)"
  if [[ "$HOSTS_WORKAROUND" == 1 ]]; then
    if (( CONNECTORS == 1 )); then r1="$R1_C1 $R1_C2"; r2="$R2_C1 $R2_C2"
    elif (( n % 2 == 1 )); then r1="$R1_C1"; r2="$R2_C1"; else r1="$R1_C2"; r2="$R2_C2"; fi
    grep -v 'argotunnel\.com' /etc/hosts > "$hosts.tmp"
    for ip in $r1; do echo "$ip region1.v2.argotunnel.com"; done >> "$hosts.tmp"
    for ip in $r2; do echo "$ip region2.v2.argotunnel.com"; done >> "$hosts.tmp"
    mv -f "$hosts.tmp" "$hosts"
    # bash execs cloudflared, so the recorded pid ends up being cloudflared itself.
    nohup unshare --user --map-root-user --mount bash -c 'mount --bind "$1" /etc/hosts && shift && exec "$@"' \
      cpa-tunnel "$hosts" "$CF" "${args[@]}" >>"$log" 2>&1 </dev/null &
  else
    nohup "$CF" "${args[@]}" >>"$log" 2>&1 </dev/null &
  fi
  echo $! > "$DIR/$pf"
  sleep 3
  if ! alive "$pf"; then echo "Connector $n failed to start; last log lines:" >&2; tail -c +$((off + 1)) "$log" | tail -n 10 >&2; return 1; fi
  echo "Connector $n started (pid $(cat "$DIR/$pf"), $TUNNEL_PROTOCOL, metrics 127.0.0.1:$port), log: $log"
  if [[ "$TUNNEL_MODE" == quick ]]; then
    url=""
    for _ in $(seq 1 30); do
      url="$(tail -c +$((off + 1)) "$log" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -n1)"
      [[ -n "$url" ]] && break; sleep 1
    done
    if [[ -n "$url" ]]; then
      old="$(head -n1 "$DIR/PUBLIC_URL.txt" 2>/dev/null)"
      echo "$url" > "$DIR/PUBLIC_URL.txt"
      echo "Quick tunnel URL: $url"; [[ -n "$old" && "$old" != "$url" ]] && echo "NOTE: URL changed (was $old)"
    else echo "WARNING: quick tunnel URL not found in $log yet" >&2; fi
  fi
  return 0
}
case "${1:-all}" in
  all) rc=0; for n in $(connectors); do start_one "$n" || rc=1; done; exit $rc ;;
  [1-9]) (( $1 <= CONNECTORS )) || { echo "connector $1 not configured (CONNECTORS=$CONNECTORS)" >&2; exit 2; }; start_one "$1" ;;
  *) echo "usage: $0 [N|all]" >&2; exit 2 ;;
esac
