#!/usr/bin/env bash
# Stop the CPA watchdog first (so it does not restart anything), then the tunnel and CPA.
# Restart everything with: start-watchdog.sh (it starts CPA and the tunnel).
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
"$CPA_DIR/stop-watchdog.sh"; "$CPA_DIR/stop-tunnel.sh"; "$CPA_DIR/stop.sh"
