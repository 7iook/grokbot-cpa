#!/usr/bin/env bash
# Claude OAuth login helper around `cli-proxy-api -claude-login -no-browser`.
# Usage:
#   claude-login.sh start        start the login in the background and print the authorize URL
#   claude-login.sh status       LOGGED_IN / WAITING / NOT_RUNNING (+ auth file count)
#   claude-login.sh paste URL    hand the final callback URL (http://localhost:54545/callback?...)
#                                to the waiting login, for when the browser ran on another machine
#   claude-login.sh stop         abort a waiting login
# Open the URL in a browser ON THIS MACHINE (e.g. the bot's own box browser) and sign in; the
# redirect to http://localhost:54545/callback then completes the login by itself. The credential
# lands in AUTH_DIR and the running CLIProxyAPI picks it up without a restart.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
LOG="$DIR/logs/claude-login.log"; FIFO="$DIR/.claude-login.fifo"; OFF="$DIR/.claude-login.offset"
new_log() { tail -c +$(( $(cat "$OFF" 2>/dev/null || echo 0) + 1 )) "$LOG" 2>/dev/null; }
auth_count() { find "${AUTH_DIR:-/nonexistent}" -maxdepth 1 -name 'claude-*.json' 2>/dev/null | wc -l; }
case "${1:-}" in
  start)
    [[ -x "$DIR/cli-proxy-api" ]] || { echo "ERROR: run install.sh first" >&2; exit 1; }
    if ! alive claude-login.pid; then
      rm -f "$FIFO"; mkfifo -m 600 "$FIFO"
      stat -c %s "$LOG" > "$OFF" 2>/dev/null || echo 0 > "$OFF"
      # stdin is a FIFO held open read-write, so the login keeps waiting instead of seeing EOF.
      nohup bash -c 'exec 3<>"$1"; exec "$2" -claude-login -no-browser -config "$3" <&3' \
        claude-login "$FIFO" "$DIR/cli-proxy-api" "$DIR/config.yaml" >>"$LOG" 2>&1 &
      echo $! > "$DIR/claude-login.pid"
    fi
    url=""
    for _ in $(seq 1 30); do
      url="$(new_log | grep -oE 'https://claude\.ai/oauth/authorize[^[:space:]]+' | tail -n1)"
      [[ -n "$url" ]] && break; alive claude-login.pid || break; sleep 1
    done
    if [[ -z "$url" ]]; then echo "ERROR: no authorize URL yet; log tail:" >&2; new_log | tail -n 15 >&2; exit 1; fi
    echo "Open this URL in a browser on this machine and sign in to Claude:"; echo "$url" ;;
  status)
    if new_log | grep -qiE 'authentication successful|Authentication saved'; then echo "LOGGED_IN (claude auth files: $(auth_count))"
    elif alive claude-login.pid; then echo "WAITING for browser sign-in (claude auth files: $(auth_count))"
    else echo "NOT_RUNNING (claude auth files: $(auth_count))"; new_log | grep -iE 'error|fail' | tail -n 5; fi ;;
  paste)
    [[ -n "${2:-}" ]] || { echo "usage: $0 paste CALLBACK_URL" >&2; exit 2; }
    alive claude-login.pid || { echo "ERROR: no login is waiting; run '$0 start' first" >&2; exit 1; }
    printf '%s\n' "$2" > "$FIFO"; sleep 5; "$0" status ;;
  stop) stop_pidfile "Claude login" claude-login.pid; rm -f "$FIFO" ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
