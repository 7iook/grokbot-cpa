#!/usr/bin/env bash
# Show CLIProxyAPI, tunnel, keepalive and watchdog status (read-only; starts nothing).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
st() { if alive "$2"; then echo "$1: RUNNING (pid $(cat "$DIR/$2"))"; else echo "$1: NOT RUNNING"; fi; }
echo "install dir: $DIR   mode: $TUNNEL_MODE   protocol: $TUNNEL_PROTOCOL   hosts workaround: $HOSTS_WORKAROUND"
st CLIProxyAPI cli-proxy-api.pid
echo "  local $LOCAL_URL/ -> HTTP $(http_code "$LOCAL_URL/" 5)"
for n in $(connectors); do
  st "connector $n" "tunnel$n.pid"; probe_connector "$n"
  echo "  metrics 127.0.0.1:$(metrics_port "$n")  ready=$READY  ha_connections=$CONNS"
done
URL="$(public_url)"
[[ -n "$URL" ]] && echo "public url: $URL -> HTTP $(http_code "$URL/" 15)"
(( CONNECTORS > 0 )) && st keepalive keepalive.pid
st watchdog watchdog.pid
if alive claude-login.pid; then echo "claude login: WAITING for browser sign-in (claude-login.sh status)"; fi
echo "auth files in ${AUTH_DIR:-?}: $(find "${AUTH_DIR:-/nonexistent}" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
