#!/usr/bin/env bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# ctl.sh — control the box-activity test.
#   ctl.sh start-monitor   # start monitor only (baseline/control phase)
#   ctl.sh start-browse    # start browse loop
#   ctl.sh start-all       # both
#   ctl.sh stop            # graceful stop both (touch .stop), then clear
#   ctl.sh status          # show pids + last log lines + quick stats
set -uo pipefail
DIR="${ACTIVITY_DIR:-$HOME/box-activity-test}"
cd "$DIR" || exit 1

launch() { # $1 script name
  local s="$DIR/$1"
  # double-fork via setsid so it survives ssh session exit
  setsid bash "$s" >/dev/null 2>&1 < /dev/null &
  sleep 1
}

running() { # $1 lockname -> echoes pid if alive
  local p="$DIR/$1/pid"
  [ -f "$p" ] || return 1
  local pid; pid=$(cat "$p" 2>/dev/null); [ -n "$pid" ] && [ -d "/proc/$pid" ] && echo "$pid"
}

case "${1:-status}" in
  start-monitor) rm -f "$DIR/.stop"; launch monitor.sh; echo "monitor: $(running .monitor.lock || echo '?')" ;;
  start-browse)  rm -f "$DIR/.stop"; launch browse-loop.sh; echo "browse: $(running .browse.lock || echo '?')" ;;
  start-all)     rm -f "$DIR/.stop"; launch monitor.sh; launch browse-loop.sh;
                 echo "monitor: $(running .monitor.lock || echo '?')  browse: $(running .browse.lock || echo '?')" ;;
  stop)          touch "$DIR/.stop"; echo "stop flag set; waiting up to 65s..."; 
                 for i in $(seq 1 65); do
                   m=$(running .monitor.lock || true); b=$(running .browse.lock || true)
                   [ -z "$m" ] && [ -z "$b" ] && break; sleep 1
                 done
                 pkill -9 -f "user-data-dir=$DIR/chrome-profile" 2>/dev/null
                 rm -f "$DIR/.stop"
                 echo "stopped. monitor:$(running .monitor.lock || echo gone) browse:$(running .browse.lock || echo gone)" ;;
  status)
     echo "monitor pid: $(running .monitor.lock || echo 'not running')"
     echo "browse  pid: $(running .browse.lock || echo 'not running')"
     echo "--- last 3 browse cycles ---"; tail -n 3 "$DIR/logs/browse.ndjson" 2>/dev/null
     echo "--- last 5 monitor rows ---"; tail -n 5 "$DIR/logs/monitor.csv" 2>/dev/null
     echo "--- monitor quick stats (pauses & non-200) ---"
     if [ -f "$DIR/logs/monitor.csv" ]; then
       awk -F, 'NR>1{t++; if($3!=200)bad++; if($7+0>5)pz++} END{printf "ticks=%d  non200_mgmt=%d  pause_events=%d\n",t,bad+0,pz+0}' "$DIR/logs/monitor.csv"
     fi ;;
  *) echo "usage: ctl.sh {start-monitor|start-browse|start-all|stop|status}"; exit 1 ;;
esac
