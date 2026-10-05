# shellcheck shell=bash
# Shared helpers for the grokbot-cpa runtime scripts. Sourced by every script; not run directly.
# Settings come from cpa.env next to this file (written by install.sh).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1
# shellcheck disable=SC1091
[[ -f "$DIR/cpa.env" ]] && . "$DIR/cpa.env"
PORT="${PORT:-8317}"
METRICS_BASE="${METRICS_BASE:-20250}"
TUNNEL_MODE="${TUNNEL_MODE:-none}"
TUNNEL_PROTOCOL="${TUNNEL_PROTOCOL:-http2}"
HOSTS_WORKAROUND="${HOSTS_WORKAROUND:-0}"
case "$TUNNEL_MODE" in
  named) CONNECTORS="${CONNECTORS:-2}"; (( CONNECTORS < 1 || CONNECTORS > 2 )) && CONNECTORS=2 ;;
  quick) CONNECTORS=1; MIN_CONNS="${MIN_CONNS:-1}" ;;   # quick tunnels hold a single HA connection
  *)     TUNNEL_MODE=none; CONNECTORS=0 ;;
esac
MIN_CONNS="${MIN_CONNS:-2}"   # named: healthy = /ready 200 and >= 2 of its 4 HA connections
LOCAL_URL="http://127.0.0.1:$PORT"
mkdir -p "$DIR/logs"

# Last-resort edge IPs (each completed TLS on :7844 on 2026-10-04). install.sh / probe-edges.sh
# overwrite these with freshly probed lists in edge-ips.env.
R1_C1="198.41.192.7 198.41.192.27 198.41.192.47 198.41.192.67 198.41.192.107 198.41.192.227"
R2_C1="198.41.200.13 198.41.200.33 198.41.200.53 198.41.200.73 198.41.200.193"
R1_C2="198.41.192.17 198.41.192.37 198.41.192.57 198.41.192.77 198.41.192.167 198.41.192.237"
R2_C2="198.41.200.23 198.41.200.43 198.41.200.63 198.41.200.113 198.41.200.233"
# shellcheck disable=SC1091
[[ -f "$DIR/edge-ips.env" ]] && . "$DIR/edge-ips.env"

connectors() { (( CONNECTORS > 0 )) && seq 1 "$CONNECTORS"; return 0; }
metrics_port() { echo $((METRICS_BASE + $1)); }
http_code() { curl -s -o /dev/null -m "${2:-10}" -w '%{http_code}' "$1" 2>/dev/null || true; }

# Public URL: quick mode -> whatever the running quick tunnel reported (PUBLIC_URL.txt);
# named mode -> PUBLIC_URL from cpa.env (falls back to PUBLIC_URL.txt).
public_url() {
  local u=""
  if [[ "$TUNNEL_MODE" == named && -n "${PUBLIC_URL:-}" ]]; then u="$PUBLIC_URL"
  elif [[ "$TUNNEL_MODE" != none ]]; then u="$(head -n1 "$DIR/PUBLIC_URL.txt" 2>/dev/null)"; fi
  u="$(printf '%s' "$u" | tr -d '[:space:]')"; printf '%s' "${u%/}"
}

# What each pid file's process cmdline must contain. Used to detect stale pid files
# (e.g. after a reboot the pid was reused by an unrelated process).
pid_pattern() {
  case "$1" in
    cli-proxy-api.pid) echo "cli-proxy-api -config $DIR/config.yaml" ;;
    tunnel[0-9].pid)   local n="${1#tunnel}"; n="${n%.pid}"; echo "--metrics 127.0.0.1:$(metrics_port "$n")" ;;
    keepalive.pid)     echo "keepalive-loop $DIR" ;;
    watchdog.pid)      echo "$DIR/watchdog.sh" ;;
    claude-login.pid)  echo "-claude-login -no-browser -config $DIR/config.yaml" ;;
    *)                 echo "$1" ;;
  esac
}

# alive PIDFILE: the pid runs AND its cmdline matches; otherwise the stale pid file is removed.
alive() {
  local f="$DIR/$1" pid pat
  [[ -f "$f" ]] || return 1
  pid="$(tr -dc '0-9' < "$f")"
  pat="$(pid_pattern "$1")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null \
     && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$pat"; then return 0; fi
  rm -f "$f"; return 1
}

# stop_pidfile NAME PIDFILE [children]: stop only the process recorded in the pid file.
stop_pidfile() {
  local name="$1" pf="$2" kids="${3:-}" pid
  if ! alive "$pf"; then echo "$name: not running"; rm -f "$DIR/$pf"; return 0; fi
  pid="$(tr -dc '0-9' < "$DIR/$pf")"
  [[ -n "$kids" ]] && pkill -P "$pid" 2>/dev/null
  kill "$pid" 2>/dev/null
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  echo "$name stopped (pid $pid)"; rm -f "$DIR/$pf"
}

# probe_connector N: sets READY (HTTP code of /ready) and CONNS (ha_connections); 0 if healthy.
probe_connector() {
  local port; port="$(metrics_port "$1")"
  READY="$(http_code "http://127.0.0.1:$port/ready" 5)"
  CONNS="$(curl -s -m 5 "http://127.0.0.1:$port/metrics" 2>/dev/null | awk '/^cloudflared_tunnel_ha_connections /{print int($2)}')"
  CONNS="${CONNS:-0}"
  [[ "$READY" == 200 ]] && (( CONNS >= MIN_CONNS ))
}
