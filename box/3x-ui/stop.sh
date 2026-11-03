#!/usr/bin/env bash
# stop x-ui, xray, the 3x-ui tunnel and the watchdog; boot-services.sh will not relaunch until start.sh is run
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); touch "$R/.watchdog-stopped"
p=$(cat "$R/watchdog.pid" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
for i in $(seq 1 20); do flock -n "$R/.watchdog.lock" true 2>/dev/null && break; sleep 0.5; done
"$R/tunnel.sh" stop >/dev/null 2>&1
pkill -f "^$R/app/x-ui( |$)" 2>/dev/null; pkill -f "^$R/app/bin/xray-linux" 2>/dev/null; echo "3x-ui stopped"
