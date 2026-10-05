#!/usr/bin/env bash
# Stop only the watchdog loop recorded in watchdog.pid (and its sleep/curl children).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
stop_pidfile Watchdog watchdog.pid children
