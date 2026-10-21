# shellcheck shell=bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# shared settings for CPA scripts
CPA_DIR=${CPA_DIR:-$HOME/cli-proxy-api}
CPA_BIN=$CPA_DIR/bin/cli-proxy-api
CPA_CONFIG=$CPA_DIR/config.yaml
CPA_PIDFILE=$CPA_DIR/cpa.pid
CPA_PORT=${CPA_PORT:-8317}
CPA_HOST=127.0.0.1
WD_PIDFILE=$CPA_DIR/watchdog.pid
WD_LOCK=$CPA_DIR/.watchdog.lock          # held by the live watchdog (single instance)
WD_STOPPED=$CPA_DIR/.watchdog-stopped    # set by stop-watchdog.sh: boot hook / tailscale watchdog won't relaunch it
LOG_DIR=$CPA_DIR/logs
WD_HEARTBEAT=$LOG_DIR/watchdog.heartbeat
LOG_TZ=${LOG_TZ:-Asia/Shanghai}   # fixed log timezone: the box's own TZ differs between resets (PDT/UTC/CST seen)
# Clean environment for long-running daemons: agent shells carry injected secrets that must not leak into them.
CLEAN_ENV=(env -i HOME=$HOME USER=$(id -un) LOGNAME=$(id -un) SHELL=/bin/bash LANG=C.UTF-8
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
# Pidfiles survive a box reset, and the old pid may now belong to an unrelated process, so a pid only counts
# if it is alive and its command line matches. (A zombie has an empty cmdline, so it does not count either.)
pid_is()      { [ -n "$1" ] && { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null | grep -Eq "$2"; }
pidfile_is()  { local p; p=$(cat "$1" 2>/dev/null) && pid_is "$p" "$2"; }
lock_held()   { ! flock -n "$1" true 2>/dev/null; }
file_age()    { local m; m=$(stat -c %Y "$1" 2>/dev/null) || { echo 0; return; }; echo $(( $(date +%s) - m )); }
# copy+truncate (writers append with O_APPEND, so they carry on in the emptied file)
rotate_log()  { local s; s=$(stat -c %s "$1" 2>/dev/null) || return 0; [ "$s" -gt "${2:-10485760}" ] || return 0
  cp -f "$1" "$1.1" && : > "$1"; }
cpa_running() { pidfile_is "$CPA_PIDFILE" "^$CPA_BIN "; }
wd_running()  { lock_held "$WD_LOCK"; }
port_open()   { (exec 3<>/dev/tcp/$CPA_HOST/$CPA_PORT) 2>/dev/null; }
http_ok()     { [ "$(curl -s -m 4 -o /dev/null -w '%{http_code}' "http://$CPA_HOST:$CPA_PORT/")" != 000 ]; }
CF_BIN=$CPA_DIR/bin/cloudflared
CF_CONFIG=$CPA_DIR/cloudflared/config.yml
CF_PIDFILE=$CPA_DIR/tunnel.pid
CF_TUNNEL=${CF_TUNNEL:-cpa}
CF_HOSTNAME=${CF_HOSTNAME:-}
CF_METRICS=127.0.0.1:20241
tunnel_running() { pidfile_is "$CF_PIDFILE" "^$CF_BIN "; }
tunnel_ready()   { curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$CF_METRICS/ready" | grep -q 200; }
# --- tunnel resilience (added 2026-10-15) ---
# The box is a KVM sandbox that gets paused / snapshot-restored ("random: crng reseeded due to virtual
# machine fork" in dmesg). While paused, cloudflared cannot heartbeat, the edge drops the tunnel
# connections and the NAT flows die, but after resume cloudflared still believes its 4 connections are
# up (/ready=200) until TCP keepalive gives up minutes later -> public 530/502. So: detect a resume and
# refresh the connectors immediately.
TUNNEL_LOCK=$CPA_DIR/.tunnel.lock
RESUME_STATE=$CPA_DIR/.resume-state
# Prints a reason and returns 0 if the VM was paused or forked since the previous call (any caller).
vm_resumed() {
  ( flock -w 10 8 || exit 1
    local off forks prev_off="" prev_forks=""
    off=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
    forks=$(dmesg 2>/dev/null | grep -c 'virtual machine fork'); forks=${forks:-0}
    [ -f "$RESUME_STATE" ] && read -r prev_off prev_forks < "$RESUME_STATE"
    echo "$off $forks" > "$RESUME_STATE"
    [ -n "$prev_off" ] || exit 1
    if [ $((off - prev_off)) -gt 10 ]; then echo "VM was paused ~$((off - prev_off))s"; exit 0; fi
    if [ "$forks" -gt "${prev_forks:-0}" ]; then echo "VM snapshot-restored (fork #$forks)"; exit 0; fi
    exit 1
  ) 8>"$CPA_DIR/.resume.lock"
}
# Returns 0 if any cloudflared edge connection has unacked data and no ACK for >20s (dead/blackholed flow).
tunnel_conns_stale() {
  local pid; tunnel_running || return 1; pid=$(cat "$CF_PIDFILE")
  ss -tinpH state established '( dport = :7844 )' 2>/dev/null | awk -v pid="pid=$pid," '
    /users:/ { mine = index($0, pid) > 0; next }
    mine { u = 0; la = 0
      if (match($0, /unacked:[0-9]+/)) u = substr($0, RSTART + 8, RLENGTH - 8) + 0
      if (match($0, /lastack:[0-9]+/)) la = substr($0, RSTART + 8, RLENGTH - 8) + 0
      if (u > 0 && la > 20000) bad = 1; mine = 0 }
    END { exit bad ? 0 : 1 }'
}
# --- peer: the Tailscale watchdog (the two watchdogs relaunch each other; there is no cron/systemd here) ---
TS_DIR=${TS_DIR:-$HOME/tailscale}
TS_WD_LOCK=$TS_DIR/.watchdog.lock
TS_WD_PIDFILE=$TS_DIR/watchdog.pid
TS_WD_HEARTBEAT=$TS_DIR/watchdog.heartbeat
BOOT_SERVICES=${BOOT_SERVICES:-$HOME/boot-services.sh}
