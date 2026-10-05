#!/usr/bin/env bash
# One-shot health check that also repairs: starts whatever is down (CLIProxyAPI, tunnel connectors,
# keepalive, watchdog), then verifies local HTTP, an authenticated /v1/models call, connector
# readiness and the public URL.
# This is also the start-after-reboot path: there is no systemd on a Grok Bot box, so an hourly
# routine runs this; after a reboot every pid file is stale (detected by cmdline) and everything starts.
# Output: one line per component, "public url: ..." and a final "RESULT: OK|FIXED|FAILED".
# In quick mode a changed URL is reported as "NOTE: public URL changed ...".
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
LOG="$DIR/logs/healthcheck.log"
fixed=0; failed=0
check() { # name pidfile startcmd...
  local name="$1" pf="$2"; shift 2
  if alive "$pf"; then echo "$name: running"
  elif "$@" >/dev/null 2>&1 && alive "$pf"; then echo "$name: RESTARTED"; fixed=1
  else echo "$name: FAILED to start (see $DIR/logs/)"; failed=1; fi
}
check "CLIProxyAPI" cli-proxy-api.pid "$DIR/start.sh"
local_code="$(http_code "$LOCAL_URL/" 10)"
echo "local http: $local_code"; [[ "$local_code" == 200 ]] || failed=1
api_code=skip
if [[ -s "$DIR/API_KEY.txt" ]]; then
  api_code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$(head -n1 "$DIR/API_KEY.txt")") "$LOCAL_URL/v1/models" 2>/dev/null || true)"
  echo "local /v1/models with API key: $api_code"; [[ "$api_code" == 200 ]] || failed=1
fi
for n in $(connectors); do check "tunnel connector $n" "tunnel$n.pid" "$DIR/start-tunnel.sh" "$n"; done
if (( CONNECTORS > 0 )); then check "keepalive" keepalive.pid "$DIR/start-keepalive.sh"; fi
check "watchdog" watchdog.pid "$DIR/start-watchdog.sh"
total=0; ready=0; code=n/a; URL=""
if (( CONNECTORS > 0 )); then
  (( fixed )) && sleep 15   # let freshly started connectors register
  for n in $(connectors); do
    probe_connector "$n"; total=$((total + CONNS)); [[ "$READY" == 200 ]] && ready=$((ready + 1))
    echo "connector $n: ready=$READY connections=$CONNS"
  done
  (( ready >= 1 )) || failed=1
  URL="$(public_url)"
  if [[ -z "$URL" ]]; then echo "public url: (unknown)"; failed=1
  else
    for _ in 1 2 3; do code="$(http_code "$URL/" 15)"; [[ "$code" == 200 ]] && break; sleep 10; done
    echo "public url: $URL HTTP $code"; [[ "$code" == 200 ]] || failed=1
    last="$(head -n1 "$DIR/.last-url" 2>/dev/null)"
    [[ -n "$last" && "$last" != "$URL" ]] && echo "NOTE: public URL changed from $last to $URL (clients must be updated)"
    echo "$URL" > "$DIR/.last-url"
  fi
  (( ready < CONNECTORS && ! failed )) && echo "note: only $ready of $CONNECTORS connectors ready (the watchdog handles this)"
else
  echo "public url: none (TUNNEL_MODE=none)"
fi
if (( failed )); then r=FAILED; elif (( fixed )); then r=FIXED; else r=OK; fi
echo "RESULT: $r"
echo "$(date '+%F %T') $r local=$local_code api=$api_code public=$code connectors_ready=$ready/$CONNECTORS connections=$total" >> "$LOG"
[[ "$r" != FAILED ]]
