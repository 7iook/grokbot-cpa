#!/usr/bin/env bash
# start (or ensure) the 3x-ui watchdog; it starts x-ui
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); rm -f "$R/.watchdog-stopped"
env -i HOME=$HOME USER=$(id -un) LOGNAME=$(id -un) SHELL=/bin/bash LANG=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  setsid -f /bin/bash "$R/watchdog.sh" >>"$R/logs/watchdog.log" 2>&1 </dev/null
echo "3x-ui watchdog launched"
