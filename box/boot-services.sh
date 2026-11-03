#!/usr/bin/env bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# Boot hook for the box's long-running services (CPA + Cloudflare tunnel, Tailscale).
# A Grok Bot box has no systemd/cron (PID 1 is tini) and its desktop is only a window manager, so XDG autostart
# (~/.config/autostart/*.desktop, kept for compat) does NOT fire. The real trigger chain is:
#   bot wakes -> first agent Shell -> exec-daemon initializes it with `bash -ilc` -> ~/.profile / ~/.bashrc
#   -> grokbot-cpa hook block (written by install-box.sh) -> this script.
# Optional fallback: a Grok Bot routine `@every 10m` running `bash ~/boot-services.sh`.
# After a VM swap /home/box is restored asynchronously (box copy-in); we wait for it (COPYIN_WAIT, default 900s).
# Cheap and idempotent: it only launches a supervisor whose single-instance lock is free. Supervisors are started
# with a clean environment (no agent-session secrets) and detached (setsid).
CPA_DIR=${CPA_DIR:-$HOME/cli-proxy-api}; TS_DIR=${TS_DIR:-$HOME/tailscale}; LOG=$CPA_DIR/logs/boot.log
CLEAN_ENV=(env -i HOME=$HOME USER=$(id -un) LOGNAME=$(id -un) SHELL=/bin/bash LANG=C.UTF-8
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
exec 9>/tmp/boot-services.lock; flock -n 9 || exit 0
free() { flock -n "$1" true 2>/dev/null; }
log() { mkdir -p "${LOG%/*}"; echo "$(TZ=${LOG_TZ:-Asia/Shanghai} date '+%F %T %Z') [$$] $*" >>"$LOG"; }
# wait until the platform finished restoring /home/box (skip if the status file is absent)
CS=/tmp/sand-copy-in-status.json
if [ -r "$CS" ]; then
  w=0; while [ $w -lt "${COPYIN_WAIT:-900}" ]; do
    ph=$(sed -nE 's/.*"phase" *: *"([a-z]+)".*/\1/p' "$CS" 2>/dev/null | head -1)
    case "$ph" in copying|pending|starting|"") sleep 5; w=$((w+5));; *) break;; esac
  done
  [ $w -gt 0 ] && log "waited ${w}s for home restore (phase=${ph:-?})"
fi
# 0. non-persistent system state: apt packages (ssh, gcc, libs for browsers...) are re-ensured on every boot
miss=""; for p in ${BOOT_APT_PKGS:-curl jq openssh-client}; do dpkg -s "$p" >/dev/null 2>&1 || dpkg -s "${p}t64" >/dev/null 2>&1 || miss="$miss $p"; done
if [ -n "$miss" ]; then log "apt missing:$miss -> installing"
  { sudo -n timeout 300 apt-get update -qq && sudo -n DEBIAN_FRONTEND=noninteractive timeout 600 apt-get install -y -qq $miss; } >>"$LOG" 2>&1 9>&- || log "apt install failed"
fi
# Swap (added 2026-11-03): the box has 16G RAM and no swap; AdsPower filling it starved CPA into a watchdog kill loop.
# /swapfile is root-owned system state that does not survive a VM swap, so (re)create and enable it on every wake.
# Opt-out: BOOT_SWAP_SIZE=0 in box.env. Runs detached so it never delays the services below.
SWAP_FILE=${BOOT_SWAP_FILE:-/swapfile}; SWAP_SIZE=${BOOT_SWAP_SIZE:-8G}
if [ "$SWAP_SIZE" != 0 ] && ! grep -q "^$SWAP_FILE " /proc/swaps 2>/dev/null && sudo -n true 2>/dev/null; then
  "${CLEAN_ENV[@]}" SWAP_FILE="$SWAP_FILE" SWAP_SIZE="$SWAP_SIZE" LOG="$LOG" setsid -f /bin/bash -c '
    ts() { TZ=Asia/Shanghai date "+%F %T %Z"; }
    { [ -f "$SWAP_FILE" ] || sudo -n fallocate -l "$SWAP_SIZE" "$SWAP_FILE"; } &&
    sudo -n chmod 600 "$SWAP_FILE" && { sudo -n swapon "$SWAP_FILE" 2>/dev/null || { sudo -n mkswap "$SWAP_FILE" >/dev/null && sudo -n swapon "$SWAP_FILE"; }; } &&
      echo "$(ts) swap $SWAP_FILE ($SWAP_SIZE) enabled" >>"$LOG" || echo "$(ts) swap $SWAP_FILE setup FAILED" >>"$LOG"' </dev/null >/dev/null 2>&1 9>&-
fi
if [ -d "$CPA_DIR" ] && [ ! -f "$CPA_DIR/.watchdog-stopped" ] && free "$CPA_DIR/.watchdog.lock"; then
  # after a reset apt packages or the binary may be missing -> bootstrap installs them (it does not start anything here)
  need=""; for c in curl jq flock pgrep ss; do command -v "$c" >/dev/null || need="$need $c"; done
  [ -x "$CPA_DIR/bin/cli-proxy-api" ] || need="$need cli-proxy-api"
  if [ -n "$need" ] && [ -x ${CPA_BOOTSTRAP:-$HOME/cpa-bootstrap.sh} ]; then
    log "missing:$need -> cpa-bootstrap.sh"; BOOT_SERVICES_CHILD=1 ${CPA_BOOTSTRAP:-$HOME/cpa-bootstrap.sh} >>"$LOG" 2>&1 9>&-
  fi
  log "uptime $(cut -d. -f1 /proc/uptime)s: starting CPA watchdog"
  "${CLEAN_ENV[@]}" setsid -f /bin/bash "$CPA_DIR/watchdog.sh" >>"$CPA_DIR/logs/watchdog.log" 2>&1 </dev/null 9>&-
fi
if [ -x "$TS_DIR/ensure-up.sh" ] && [ ! -f "$TS_DIR/.watchdog-stopped" ] && free "$TS_DIR/.watchdog.lock"; then
  log "uptime $(cut -d. -f1 /proc/uptime)s: starting Tailscale (ensure-up + watchdog)"
  "${CLEAN_ENV[@]}" setsid -f /bin/bash "$TS_DIR/ensure-up.sh" >/dev/null 2>&1 </dev/null 9>&-
fi
# keepalives: cmcc has its own autostart entry; box-activity is (re)launched here unless stopped on purpose
AD=${ACTIVITY_DIR:-$HOME/box-activity-test}
if [ -x "$AD/ctl.sh" ] && [ ! -f "$AD/.stop" ] && free "$AD/.supervise.lock"; then
  "${CLEAN_ENV[@]}" setsid -f /bin/bash "$AD/supervise.sh" >/dev/null 2>&1 </dev/null 9>&-; log "box-activity supervisor launched"
fi
CD=${CMCC_DIR:-$HOME/cmcc-cloud-alive}
[ -x "$CD/supervise.sh" ] && [ ! -f "$CD/.stop" ] && free "$CD/.supervise.lock" && "${CLEAN_ENV[@]}" setsid -f /bin/bash "$CD/supervise.sh" >/dev/null 2>&1 </dev/null 9>&-
# 3x-ui (optional, box/3x-ui -> $XUI_DIR): its watchdog supervises x-ui + xray + its own cloudflared tunnel.
# Opt-out: touch $XUI_DIR/.watchdog-stopped (stop.sh does it; start.sh clears it).
XD=${XUI_DIR:-$HOME/3x-ui}
if [ -x "$XD/watchdog.sh" ] && [ -x "$XD/app/x-ui" ] && [ ! -f "$XD/.watchdog-stopped" ] && free "$XD/.watchdog.lock"; then
  mkdir -p "$XD/logs"; "${CLEAN_ENV[@]}" setsid -f /bin/bash "$XD/watchdog.sh" >>"$XD/logs/watchdog.log" 2>&1 </dev/null 9>&-
  log "3x-ui watchdog launched"
fi
exit 0
