#!/usr/bin/env bash
# Read-only overview of CPA, tunnel, watchdogs, Tailscale and keepalives. Starts nothing, prints no secrets.
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if cpa_running; then echo "cpa: RUNNING (pid $(cat "$CPA_PIDFILE")) port $CPA_PORT http=$(curl -s -o /dev/null -m 4 -w '%{http_code}' "http://$CPA_HOST:$CPA_PORT/")"; else echo "cpa: NOT RUNNING"; fi
if wd_running; then echo "cpa watchdog: RUNNING (pid $(cat "$WD_PIDFILE" 2>/dev/null)) heartbeat age $(file_age "$WD_HEARTBEAT")s"
else echo "cpa watchdog: NOT RUNNING$([ -f "$WD_STOPPED" ] && echo ' (stopped on purpose: .watchdog-stopped)')"; fi
if [ -f "$CF_CONFIG" ]; then
  if tunnel_running; then echo "tunnel $CF_TUNNEL: RUNNING (pid $(cat "$CF_PIDFILE")) ready=$(tunnel_ready && echo yes || echo no)"; else echo "tunnel $CF_TUNNEL: NOT RUNNING"; fi
  [ -n "$CF_HOSTNAME" ] && echo "public https://$CF_HOSTNAME/ -> HTTP $(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$CF_HOSTNAME/")"
else echo "tunnel: not configured ($CF_CONFIG missing)"; fi
if lock_held "$TS_WD_LOCK"; then echo "tailscale watchdog: RUNNING (heartbeat age $(file_age "$TS_WD_HEARTBEAT")s)"; else echo "tailscale watchdog: NOT RUNNING"; fi
[ -x "$TS_DIR/tailscale" ] && echo "tailscale: $(sudo -n "$TS_DIR/tailscale" --socket="$TS_DIR/tailscaled.sock" status --json 2>/dev/null | jq -r '"\(.BackendState) \(.TailscaleIPs[0] // "-")"' 2>/dev/null || echo unknown)"
pgrep -f 'cmcc_cloud_alive.webui' >/dev/null && echo "keepalive cmcc: RUNNING" || echo "keepalive cmcc: not running"
pgrep -f 'box-activity-test/monitor.sh|/monitor.sh' >/dev/null && echo "keepalive box-activity: RUNNING" || echo "keepalive box-activity: not running"
echo "auth files: $(find "$CPA_DIR/auths" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l) in $CPA_DIR/auths"
