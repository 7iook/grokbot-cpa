#!/usr/bin/env bash
# Stop only the keepalive loop recorded in keepalive.pid (and its sleep child).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
stop_pidfile Keepalive keepalive.pid children
