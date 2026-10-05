#!/usr/bin/env bash
# Start everything: CLIProxyAPI, tunnel connector(s), keepalive, watchdog.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
rc=0
"$DIR/start.sh" || rc=1
if (( CONNECTORS > 0 )); then "$DIR/start-tunnel.sh" all || rc=1; "$DIR/start-keepalive.sh" || rc=1; fi
"$DIR/start-watchdog.sh" || rc=1
exit $rc
