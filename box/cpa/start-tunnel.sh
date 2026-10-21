#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
mkdir -p "$LOG_DIR"
[ -n "${TUNNEL_LOCK_HELD:-}" ] || { exec 9>"$CPA_DIR/.tunnel.lock"; flock -w 40 9; }
if tunnel_running; then echo "tunnel already running (pid $(cat $CF_PIDFILE))"; exit 0; fi
[ -x "$CF_BIN" ] && [ -f "$CF_CONFIG" ] || { echo "tunnel not configured (missing cloudflared or $CF_CONFIG)"; exit 1; }
stray=$(pgrep -f "^$CF_BIN .*--config $CF_CONFIG" || true); [ -n "$stray" ] && kill $stray 2>/dev/null && sleep 1
# The box intercepts all port-53 DNS and returns fake 198.18.x.x IPs, so edge discovery fails.
# Override via env var only (never --dns-resolver-addrs). OpenDNS on port 5353 is not intercepted.
export TUNNEL_DNS_RESOLVER_ADDRS="${TUNNEL_DNS_RESOLVER_ADDRS:-208.67.222.222:5353,208.67.220.220:5353}"
# That env var does not cover edge discovery in this build, so also pin real edge IPs (resolved via the
# same resolvers) through cloudflared's TUNNEL_EDGE env var. Falls back to normal discovery if it fails.
if [ -z "${TUNNEL_EDGE:-}" ]; then edge=$(python3 "$CPA_DIR/cloudflared/resolve-edge.py" 2>/dev/null) && [ -n "$edge" ] && export TUNNEL_EDGE="$edge"; fi
nohup "$CF_BIN" tunnel --no-autoupdate --protocol http2 --metrics "$CF_METRICS" --config "$CF_CONFIG" run "$CF_TUNNEL" >>"$LOG_DIR/tunnel.log" 2>&1 </dev/null 9>&- &
echo $! > "$CF_PIDFILE"
for i in $(seq 1 40); do tunnel_ready && { echo "tunnel started (pid $(cat $CF_PIDFILE)), connection registered"; exit 0; }; tunnel_running || break; sleep 0.5; done
tunnel_running && { echo "tunnel started (pid $(cat $CF_PIDFILE)) but not ready yet"; exit 0; }
echo "tunnel failed to start; see $LOG_DIR/tunnel.log"; exit 1
