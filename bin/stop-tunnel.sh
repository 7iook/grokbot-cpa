#!/usr/bin/env bash
# Stop tunnel connector(s) started by start-tunnel.sh (pid files only; never touches other cloudflared).
# Usage: stop-tunnel.sh [N|all]   (default: all)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
case "${1:-all}" in
  all) for f in "$DIR"/tunnel[0-9].pid; do [[ -e "$f" ]] || continue; f="$(basename "$f")"; n="${f#tunnel}"; stop_pidfile "Connector ${n%.pid}" "$f"; done; true ;;
  [1-9]) stop_pidfile "Connector $1" "tunnel$1.pid" ;;
  *) echo "usage: $0 [N|all]" >&2; exit 2 ;;
esac
