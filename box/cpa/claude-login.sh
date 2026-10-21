#!/usr/bin/env bash
# Claude OAuth login helper around `cli-proxy-api -claude-login -no-browser`.
#   claude-login.sh start | status | paste CALLBACK_URL | stop
# Open the printed URL in a browser ON THIS MACHINE (the bot's box browser); the redirect to
# http://localhost:54545/callback completes the login. The credential lands in $CPA_DIR/auths.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/claude-login.log"; FIFO="$CPA_DIR/.claude-login.fifo"; OFF="$CPA_DIR/.claude-login.offset"; PF="$CPA_DIR/claude-login.pid"
new_log() { tail -c +$(( $(cat "$OFF" 2>/dev/null || echo 0) + 1 )) "$LOG" 2>/dev/null; }
auth_count() { find "$CPA_DIR/auths" -maxdepth 1 -name 'claude-*.json' 2>/dev/null | wc -l; }
alive() { pidfile_is "$PF" "claude-login"; }
case "${1:-}" in
  start)
    [ -x "$CPA_BIN" ] || { echo "ERROR: $CPA_BIN missing; run cpa-bootstrap.sh first" >&2; exit 1; }
    if ! alive; then
      rm -f "$FIFO"; mkfifo -m 600 "$FIFO"
      stat -c %s "$LOG" > "$OFF" 2>/dev/null || echo 0 > "$OFF"
      nohup bash -c 'exec 3<>"$1"; exec "$2" -claude-login -no-browser -config "$3" <&3' \
        claude-login "$FIFO" "$CPA_BIN" "$CPA_CONFIG" >>"$LOG" 2>&1 &
      echo $! > "$PF"
    fi
    url=""
    for _ in $(seq 1 30); do
      url="$(new_log | grep -oE 'https://claude\.ai/oauth/authorize[^[:space:]]+' | tail -n1)"
      [ -n "$url" ] && break; alive || break; sleep 1
    done
    [ -n "$url" ] || { echo "ERROR: no authorize URL yet; log tail:" >&2; new_log | tail -n 15 >&2; exit 1; }
    echo "Open this URL in a browser on this machine and sign in to Claude:"; echo "$url" ;;
  status)
    if new_log | grep -qiE 'authentication successful|Authentication saved'; then echo "LOGGED_IN (claude auth files: $(auth_count))"
    elif alive; then echo "WAITING for browser sign-in (claude auth files: $(auth_count))"
    else echo "NOT_RUNNING (claude auth files: $(auth_count))"; new_log | grep -iE 'error|fail' | tail -n 5; fi ;;
  paste)
    [ -n "${2:-}" ] || { echo "usage: $0 paste CALLBACK_URL" >&2; exit 2; }
    alive || { echo "ERROR: no login is waiting; run '$0 start' first" >&2; exit 1; }
    printf '%s\n' "$2" > "$FIFO"; sleep 5; "$0" status ;;
  stop) alive && kill "$(cat "$PF")"; rm -f "$PF" "$FIFO"; echo "claude login stopped" ;;
  *) sed -n '2,5p' "$0"; exit 2 ;;
esac
