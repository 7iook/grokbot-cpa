#!/usr/bin/env bash
# tunnel.sh start|stop|restart|status  - the 3x-ui cloudflared tunnel (serialized via .tunnel.lock)
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$R/env.sh"
running() { local p; p=$(cat "$XUI_CF_PIDFILE" 2>/dev/null) && [ -n "$p" ] && { tr "\0" " " < /proc/$p/cmdline; } 2>/dev/null | grep -q "^$XUI_CF_BIN "; }
ready() { curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$XUI_CF_METRICS/ready" | grep -q 200; }
stop() { if running; then p=$(cat "$XUI_CF_PIDFILE"); kill "$p"; for i in $(seq 1 ${1:-10}); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
  kill -9 "$p" 2>/dev/null; echo "tunnel stopped"; else echo "tunnel not running"; fi; rm -f "$XUI_CF_PIDFILE"
  pkill -f "^$XUI_CF_BIN .*--config $XUI_CF_CONFIG" 2>/dev/null; true; }
start() { running && { echo "tunnel already running"; return 0; }
  pkill -f "^$XUI_CF_BIN .*--config $XUI_CF_CONFIG" 2>/dev/null; sleep 0.5
  export TUNNEL_DNS_RESOLVER_ADDRS="${TUNNEL_DNS_RESOLVER_ADDRS:-208.67.222.222:5353,208.67.220.220:5353}"
  if [ -z "${TUNNEL_EDGE:-}" ]; then edge=$(python3 "$R/cloudflared/resolve-edge.py" 2>/dev/null) && [ -n "$edge" ] && export TUNNEL_EDGE="$edge"; fi
  nohup "$XUI_CF_BIN" tunnel --no-autoupdate --protocol http2 --metrics "$XUI_CF_METRICS" --config "$XUI_CF_CONFIG" run >>"$XUI_LOG_FOLDER/tunnel.log" 2>&1 </dev/null 6>&- 9>&- &
  echo $! > "$XUI_CF_PIDFILE"
  for i in $(seq 1 40); do ready && { echo "tunnel started (pid $(cat $XUI_CF_PIDFILE)), connected"; return 0; }; running || break; sleep 0.5; done
  running && { echo "tunnel started but not ready yet"; return 0; }; echo "tunnel failed to start"; return 1; }
exec 9>"$R/.tunnel.lock"; flock -w 40 9
case "${1:-status}" in
  start) start;; stop) stop;; restart) stop "${2:-4}"; start;;
  status) running && echo "tunnel running (pid $(cat $XUI_CF_PIDFILE)) ready=$(ready && echo yes || echo no)" || echo "tunnel not running";;
esac
