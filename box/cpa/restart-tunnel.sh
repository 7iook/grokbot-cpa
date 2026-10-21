#!/usr/bin/env bash
# Serialized tunnel restart (healthcheck + watchdog both use this, so they never race).
# usage: restart-tunnel.sh [fast]   fast = don't wait for graceful drain (connections are already dead)
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
exec 9>"$TUNNEL_LOCK"; flock -w 60 9 || { echo "restart-tunnel: lock busy"; exit 1; }
export TUNNEL_LOCK_HELD=1
[ "${1:-}" = fast ] && export TUNNEL_STOP_FAST=1
"$CPA_DIR/stop-tunnel.sh"; "$CPA_DIR/start-tunnel.sh"
