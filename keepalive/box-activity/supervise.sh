#!/usr/bin/env bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# box-activity-test supervisor: single instance (flock). Keeps monitor.sh and browse-loop.sh
# alive; relaunches whichever has died. Honors $DIR/.stop (does NOT relaunch while stop flag set,
# matching ctl.sh maintenance semantics). Loop tick 10s. Safe to launch repeatedly.
# Mirrors the cmcc-cloud-alive/supervise.sh + CPA watchdog pattern already used on this box.
DIR="${ACTIVITY_DIR:-$HOME/box-activity-test}"
LOGDIR="$DIR/logs"; mkdir -p "$LOGDIR"
exec 9>"$DIR/.supervise.lock"; flock -n 9 || exit 0
log() { echo "$(date '+%F %T %Z') $*" >> "$LOGDIR/supervise.log"; }
trap 'log "supervisor stopping (signal)"; exit 0' TERM INT

alive() { # $1 lockdir name -> 0 if the loop's pid is alive AND cmd matches
  local p="$DIR/$1/pid" pid
  [ -f "$p" ] || return 1
  pid=$(cat "$p" 2>/dev/null); [ -n "$pid" ] || return 1
  [ -d "/proc/$pid" ] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "[.]sh" || return 1
  return 0
}

launch() { # $1 script
  setsid bash "$DIR/$1" >/dev/null 2>&1 </dev/null &
  sleep 1
}

log "supervisor started (pid $$)"
while true; do
  if [ -f "$DIR/.stop" ]; then
    # maintenance: user asked everything stopped; do not relaunch.
    sleep 10 & wait $!; continue
  fi
  if ! alive .monitor.lock; then
    log "monitor down -> relaunch"; launch monitor.sh
  fi
  if ! alive .browse.lock; then
    log "browse down -> relaunch"; launch browse-loop.sh
  fi
  sleep 10 & wait $!
done
