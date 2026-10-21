# shellcheck shell=bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# Shared helpers for ensure-up.sh / watchdog.sh. Never prints the auth key or state contents.
D=${TS_DIR:-$HOME/tailscale}
TS=$D/tailscale; TSD=$D/tailscaled; SOCK=$D/tailscaled.sock; PIDFILE=$D/tailscaled.pid
STATE=$D/tailscaled.state; BACKUP=$D/state-backup.json; KEY=$D/authkey
LOG=$D/tailscaled.log; ELOG=$D/ensure-up.log; WLOG=$D/watchdog.log; HOST=${TS_HOSTNAME:-cpa-box}
RESUME_STATE=$D/.resume.state; LAST_RESUME=$D/.last_resume
MIN_KILL_AGE=${MIN_KILL_AGE:-60}  # never kill a tailscaled younger than this (s, uptime-based) unless forced: a fresh
                                  # daemon needs ~40-60s to get from NoState to Running here (seen 2026-10-17 02:17)
LOG_TZ=${LOG_TZ:-Asia/Shanghai}              # fixed log timezone (the box's TZ differs between resets)
WD_PIDFILE=$D/watchdog.pid; WD_HEARTBEAT=$D/watchdog.heartbeat
# clean environment for the watchdog: agent shells carry injected secrets that must not leak into daemons
CLEAN_ENV=(env -i HOME=$HOME USER=$(id -un) LOGNAME=$(id -un) SHELL=/bin/bash LANG=C.UTF-8
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
pid_is()     { [ -n "$1" ] && { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null | grep -Eq "$2"; }
lock_held()  { ! flock -n "$1" true 2>/dev/null; }
file_age()   { local m; m=$(stat -c %Y "$1" 2>/dev/null) || { echo 0; return; }; echo $(( $(date +%s) - m )); }
# copy+truncate (tailscaled appends with O_APPEND, so it carries on in the emptied file)
rotate_log() { local s; s=$(stat -c %s "$1" 2>/dev/null) || return 0; [ "$s" -gt "${2:-10485760}" ] || return 0
  cp -f "$1" "$1.1" && : > "$1"; }
# peer: the CPA watchdog (the two watchdogs relaunch each other; there is no cron/systemd here)
CPA_DIR=${CPA_DIR:-$HOME/cli-proxy-api}; CPA_WD_LOCK=$CPA_DIR/.watchdog.lock; CPA_WD_PIDFILE=$CPA_DIR/watchdog.pid
CPA_WD_HEARTBEAT=$CPA_DIR/logs/watchdog.heartbeat; BOOT_SERVICES=${BOOT_SERVICES:-$HOME/boot-services.sh}
CLI_TIMEOUT=${CLI_TIMEOUT:-5}       # every tailscale CLI call is bounded (missing socket / hung daemon can't block)

# timeout runs inside sudo so it can actually signal the root-owned CLI
ts()  { sudo -n timeout -k 2 "$CLI_TIMEOUT" "$TS" --socket="$SOCK" "$@"; }
# live (non-zombie) tailscaled pids
tsd_pids() { local p s r=1; for p in $(pgrep -f "^$TSD( |$)"); do
    s=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null) || continue
    [ -n "$s" ] && [ "$s" != Z ] && [ "$s" != X ] && { echo "$p"; r=0; }; done; return $r; }
uptime_s() { cut -d. -f1 /proc/uptime; }
# age in seconds of running time (uptime-based)
pid_age() { local st hz; st=$(awk '{print $22}' "/proc/$1/stat" 2>/dev/null) || return 1; [ -n "$st" ] || return 1
  hz=$(getconf CLK_TCK); echo $(( $(uptime_s) - st / hz )); }
tsd_min_age() { local p a m=""; for p in $(tsd_pids); do a=$(pid_age "$p") || continue; { [ -z "$m" ] || [ "$a" -lt "$m" ]; } && m=$a; done; echo "${m:--1}"; }
status_json() { [ -S "$SOCK" ] || return 1; ts status --json 2>/dev/null; }
# BackendState, or "none" when the daemon does not answer
bstate() { local s; s=$(status_json | jq -r '.BackendState // empty' 2>/dev/null); echo "${s:-none}"; }
# "Running true" / "Starting false" / "none false"
health_pair() { local j; j=$(status_json); [ -n "$j" ] || { echo "none false"; return; }
  jq -r '"\(.BackendState // "none") \(.Self.Online == true)"' <<<"$j" 2>/dev/null || echo "none false"; }

# Detect a VM pause / snapshot-restore since the last call (wall clock jumps vs uptime, or dmesg fork count grows).
# Records the time of the last detected resume in $LAST_RESUME. Returns 0 if a resume was detected now.
detect_resume() {
  ( flock -w 5 7 || exit 1
    local off forks prev_off="" prev_forks=""
    off=$(( $(date +%s) - $(uptime_s) ))
    forks=$(dmesg 2>/dev/null | grep -c 'virtual machine fork'); forks=${forks:-0}
    [ -f "$RESUME_STATE" ] && read -r prev_off prev_forks < "$RESUME_STATE"
    echo "$off $forks" > "$RESUME_STATE"
    [ -n "$prev_off" ] || exit 1
    if [ $((off - prev_off)) -gt 10 ] || [ "$forks" -gt "${prev_forks:-0}" ]; then date +%s > "$LAST_RESUME"; exit 0; fi
    exit 1
  ) 7>"$D/.resume.lock"
}
since_resume() { local t; t=$(cat "$LAST_RESUME" 2>/dev/null); echo $(( $(date +%s) - ${t:-0} )); }

# Start tailscaled fully detached: sh forks setsid->tailscaled in the background, records its pid and exits,
# so no sudo/sh parent lingers (a lingering, stopped sudo is what kept '[tailscaled] <defunct>' around).
spawn_tsd() { # args...
  sudo -n rm -f "$SOCK" "$PIDFILE"
  sudo -n /bin/sh -c 'pf=$1; log=$2; shift 2; setsid "$@" >>"$log" 2>&1 </dev/null & echo $! >"$pf"' \
    sh "$PIDFILE" "$LOG" "$TSD" "$@" </dev/null >/dev/null 2>&1 9>&- 8>&-
}
# Kill leftover 'sudo ... tailscaled' launchers (old start method) that no longer have a live tailscaled child;
# this also reaps their zombie children (they get reparented to the subreaper).
reap_strays() {
  local p c live
  for p in $(pgrep -f "^sudo -n (setsid )?$TSD( |$)"); do
    live=0; for c in $(pgrep -P "$p"); do s=$(awk '{print $3}' "/proc/$c/stat" 2>/dev/null); [ -n "$s" ] && [ "$s" != Z ] && live=1; done
    [ $live = 0 ] && sudo -n kill -9 "$p" 2>/dev/null
  done; return 0
}
# Kill tailscaled only if it is old enough (or $2=force), then wait for it to really exit.
kill_tsd() { # $1 reason, $2 optional "force", $3 log file
  local age p pids; age=$(tsd_min_age)
  if [ "$age" = -1 ]; then reap_strays; return 0; fi
  if [ "$2" != force ] && [ "$age" -lt "$MIN_KILL_AGE" ]; then echo "$(TZ=$LOG_TZ date '+%F %T %Z') skip kill ($1): tailscaled only ${age}s old" >>"$3"; return 1; fi
  pids=$(tsd_pids | tr '\n' ' ')
  sudo -n kill -TERM $pids 2>/dev/null; sudo -n kill -CONT $pids 2>/dev/null   # CONT: a SIGSTOPped daemon must see TERM
  local i; for i in $(seq 1 10); do tsd_pids >/dev/null || break; sleep 0.5; done
  tsd_pids >/dev/null && { sudo -n kill -9 $(tsd_pids) 2>/dev/null; sleep 0.5; }
  sudo -n rm -f "$PIDFILE"; reap_strays; return 0
}
