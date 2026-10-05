#!/usr/bin/env bash
# Start CLIProxyAPI in the background (no-op if already running).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if alive cli-proxy-api.pid; then echo "CLIProxyAPI already running (pid $(cat cli-proxy-api.pid))"; exit 0; fi
[[ -x "$DIR/cli-proxy-api" && -f "$DIR/config.yaml" ]] || { echo "ERROR: binary or config.yaml missing; run install.sh first" >&2; exit 1; }
nohup "$DIR/cli-proxy-api" -config "$DIR/config.yaml" >>"$DIR/logs/cli-proxy-api.log" 2>&1 </dev/null &
echo $! > "$DIR/cli-proxy-api.pid"
for _ in $(seq 1 20); do
  sleep 1
  alive cli-proxy-api.pid || break
  [[ "$(http_code "$LOCAL_URL/" 3)" == 200 ]] && { echo "CLIProxyAPI started (pid $(cat cli-proxy-api.pid)) on $LOCAL_URL, log: $DIR/logs/cli-proxy-api.log"; exit 0; }
done
if alive cli-proxy-api.pid; then
  echo "CLIProxyAPI running (pid $(cat cli-proxy-api.pid)) but $LOCAL_URL/ is not answering yet; see logs/cli-proxy-api.log"; exit 0
fi
echo "CLIProxyAPI failed to start; last log lines:" >&2; tail -n 15 "$DIR/logs/cli-proxy-api.log" >&2; exit 1
