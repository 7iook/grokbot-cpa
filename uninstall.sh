#!/usr/bin/env bash
# Stop the box scheme and remove its autostart entries. Dry run unless --yes.
#   uninstall.sh [--yes] [--purge]   --purge also deletes $CPA_DIR (config, secrets, auths!) and $TS_DIR
set -uo pipefail
YES=0; PURGE=0
for a in "$@"; do case "$a" in --yes|-y) YES=1;; --purge) PURGE=1;; *) sed -n '2,3p' "$0"; exit 2;; esac; done
CFG="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"
# shellcheck disable=SC1090
[ -f "$CFG" ] && . "$CFG"
CPA_DIR=${CPA_DIR:-$HOME/cli-proxy-api}; TS_DIR=${TS_DIR:-$HOME/tailscale}
echo "will stop CPA watchdog/tunnel/CPA and Tailscale watchdog, remove ~/.config/autostart/{boot-services,cmcc-keepalive}.desktop"
[ $PURGE = 1 ] && echo "will DELETE $CPA_DIR and $TS_DIR (including secrets, auths, tailscale state)"
[ $YES = 1 ] || { echo "dry run; re-run with --yes"; exit 0; }
[ -x "$CPA_DIR/stop-all.sh" ] && "$CPA_DIR/stop-all.sh"
touch "$TS_DIR/.watchdog-stopped" 2>/dev/null; pkill -f "$TS_DIR/watchdog.sh" 2>/dev/null
rm -f "$HOME/.config/autostart/boot-services.desktop" "$HOME/.config/autostart/cmcc-keepalive.desktop"
if [ $PURGE = 1 ]; then sudo -n pkill -f "$TS_DIR/tailscaled" 2>/dev/null; rm -rf "$CPA_DIR"; sudo -n rm -rf "$TS_DIR"; fi
echo "uninstall finished"
