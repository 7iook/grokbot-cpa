#!/usr/bin/env bash
# Stop everything started from this directory (watchdog first so it does not restart anything).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
"$DIR/stop-watchdog.sh"; "$DIR/stop-keepalive.sh"; "$DIR/stop-tunnel.sh" all; "$DIR/stop.sh"
alive claude-login.pid && stop_pidfile "Claude login" claude-login.pid
true
