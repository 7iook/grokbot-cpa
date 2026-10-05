#!/usr/bin/env bash
# Stop only the CLIProxyAPI process recorded in cli-proxy-api.pid.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
stop_pidfile CLIProxyAPI cli-proxy-api.pid
