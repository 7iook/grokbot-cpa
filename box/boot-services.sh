#!/usr/bin/env bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# Boot hook for the box's long-running services (CPA + Cloudflare tunnel, Tailscale).
# There is no systemd/cron here (PID 1 is tini) and a box reset wipes everything except /home/box and /workspace,
# so this is called from ~/.bashrc, ~/.profile and ~/.config/autostart/boot-services.desktop.
# Cheap and idempotent: it only launches a supervisor whose single-instance lock is free. Supervisors are started
# with a clean environment (no agent-session secrets) and detached (setsid).
CPA_DIR=${CPA_DIR:-$HOME/cli-proxy-api}; TS_DIR=${TS_DIR:-/workspace/tailscale}; LOG=$CPA_DIR/logs/boot.log
CLEAN_ENV=(env -i HOME=$HOME USER=$(id -un) LOGNAME=$(id -un) SHELL=/bin/bash LANG=C.UTF-8
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
exec 9>/tmp/boot-services.lock; flock -n 9 || exit 0
free() { flock -n "$1" true 2>/dev/null; }
log() { mkdir -p "${LOG%/*}"; echo "$(TZ=${LOG_TZ:-Asia/Shanghai} date '+%F %T %Z') [$$] $*" >>"$LOG"; }
if [ -d "$CPA_DIR" ] && [ ! -f "$CPA_DIR/.watchdog-stopped" ] && free "$CPA_DIR/.watchdog.lock"; then
  # after a reset apt packages or the binary may be missing -> bootstrap installs them (it does not start anything here)
  need=""; for c in curl jq flock pgrep ss; do command -v "$c" >/dev/null || need="$need $c"; done
  [ -x "$CPA_DIR/bin/cli-proxy-api" ] || need="$need cli-proxy-api"
  if [ -n "$need" ] && [ -x ${CPA_BOOTSTRAP:-/workspace/cpa-bootstrap.sh} ]; then
    log "missing:$need -> cpa-bootstrap.sh"; BOOT_SERVICES_CHILD=1 ${CPA_BOOTSTRAP:-/workspace/cpa-bootstrap.sh} >>"$LOG" 2>&1 9>&-
  fi
  log "uptime $(cut -d. -f1 /proc/uptime)s: starting CPA watchdog"
  "${CLEAN_ENV[@]}" setsid -f /bin/bash "$CPA_DIR/watchdog.sh" >>"$CPA_DIR/logs/watchdog.log" 2>&1 </dev/null 9>&-
fi
if [ -x "$TS_DIR/ensure-up.sh" ] && [ ! -f "$TS_DIR/.watchdog-stopped" ] && free "$TS_DIR/.watchdog.lock"; then
  log "uptime $(cut -d. -f1 /proc/uptime)s: starting Tailscale (ensure-up + watchdog)"
  "${CLEAN_ENV[@]}" setsid -f /bin/bash "$TS_DIR/ensure-up.sh" >/dev/null 2>&1 </dev/null 9>&-
fi
exit 0
