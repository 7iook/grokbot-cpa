#!/usr/bin/env bash
# Deploy the "box" profile (the setup running on the reference Grok Bot box): CPA + named cloudflared tunnel
# supervised by watchdog.sh, a userspace/kernel Tailscale with its own watchdog (the two relaunch each other),
# boot via XFCE autostart (no systemd/cron on the box), and optional keepalives.
#   ./box/install-box.sh [--with-cmcc] [--with-activity]
# Secrets are NOT installed by this script. Provide them yourself afterwards:
#   $CPA_DIR/config.yaml (api keys, management secret), $CPA_DIR/auths/, $CPA_DIR/cloudflared/{config.yml,<id>.json},
#   $TS_DIR/authkey (Tailscale auth key, chmod 600).
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$HOME/.config/grokbot-cpa/box.env"
mkdir -p "${CFG%/*}"; [ -f "$CFG" ] || cp "$R/box/box.env.example" "$CFG"
# shellcheck disable=SC1090
. "$CFG"
mkdir -p "$CPA_DIR/logs" "$CPA_DIR/cloudflared" "$TS_DIR"
for f in "$R"/box/cpa/*; do install -m 755 "$f" "$CPA_DIR/"; done; chmod 644 "$CPA_DIR/common.sh"
for f in "$R"/box/tailscale/*.sh; do install -m 755 "$f" "$TS_DIR/"; done; chmod 644 "$TS_DIR/lib.sh"
install -m 755 "$R/box/boot-services.sh" "$BOOT_SERVICES"; install -m 755 "$R/box/cpa-bootstrap.sh" "$CPA_BOOTSTRAP"
mkdir -p "$HOME/.config/autostart"
sed "s#@HOME@#$HOME#g" "$R/box/autostart/boot-services.desktop" > "$HOME/.config/autostart/boot-services.desktop"
for a in "$@"; do case "$a" in
  --with-cmcc) bash "$R/keepalive/cmcc/install.sh"
     sed "s#@HOME@#$HOME#g" "$R/box/autostart/cmcc-keepalive.desktop" > "$HOME/.config/autostart/cmcc-keepalive.desktop" ;;
  --with-activity) mkdir -p "$ACTIVITY_DIR"; for f in "$R"/keepalive/box-activity/*.sh; do install -m 755 "$f" "$ACTIVITY_DIR/"; done ;;
  *) echo "unknown option $a"; exit 1 ;;
esac; done
echo "installed. Next: add secrets (see header), then: BOOT_SERVICES_CHILD= $CPA_BOOTSTRAP"
