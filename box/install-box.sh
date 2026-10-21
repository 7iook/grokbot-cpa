#!/usr/bin/env bash
# Deploy the grokbot-cpa box scheme: CPA (built from the 7iook/CLIProxyAPI fork by default) + named cloudflared
# tunnel supervised by watchdog.sh, Tailscale with its own watchdog (the two relaunch each other), boot via XFCE
# autostart (no systemd/cron on a Grok Bot box), optional keepalives. Idempotent; keeps existing config/secrets.
#   ./box/install-box.sh [--with-cmcc] [--with-activity] [--no-start]
# Settings: ~/.config/grokbot-cpa/box.env (created from box/box.env.example; env vars override on first run).
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"
WITH_CMCC=0; WITH_ACT=0; START=1
for a in "$@"; do case "$a" in --with-cmcc) WITH_CMCC=1;; --with-activity) WITH_ACT=1;; --no-start) START=0;;
  -h|--help) sed -n '2,6p' "$0"; exit 0;; *) echo "unknown option $a" >&2; exit 2;; esac; done
mkdir -p "${CFG%/*}"
if [ ! -f "$CFG" ]; then
  cp "$R/box/box.env.example" "$CFG"
  for v in CPA_DIR CPA_PORT CF_TUNNEL CF_HOSTNAME TS_DIR TS_HOSTNAME LOG_TZ CPA_BUILD CPA_SOURCE_REPO CPA_SOURCE_REF CPA_VERSION; do
    [ -n "${!v:-}" ] && sed -i -E "s#^$v=.*#$v=\"${!v}\"#" "$CFG"; done
  echo "created $CFG"
fi
# shellcheck disable=SC1090
. "$CFG"
mkdir -p "$CPA_DIR"/{bin,logs,cloudflared,auths,secrets} "$TS_DIR"; chmod 700 "$CPA_DIR/secrets" "$CPA_DIR/auths" "$CPA_DIR/cloudflared"
for f in "$R"/box/cpa/*.sh; do install -m 755 "$f" "$CPA_DIR/"; done; chmod 644 "$CPA_DIR/common.sh"
install -m 644 "$R/box/cpa/resolve-edge.py" "$CPA_DIR/cloudflared/resolve-edge.py"
for f in "$R"/box/tailscale/*.sh; do install -m 755 "$f" "$TS_DIR/"; done; chmod 644 "$TS_DIR/lib.sh"
install -m 755 "$R/box/boot-services.sh" "$BOOT_SERVICES"; install -m 755 "$R/box/cpa-bootstrap.sh" "$CPA_BOOTSTRAP"
echo "${CPA_VERSION:-v8.0.29}" > "$CPA_DIR/VERSION"
# tailscale static binaries (kept in $TS_DIR so they survive a box reset)
if [ ! -x "$TS_DIR/tailscaled" ]; then
  case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "unsupported arch" >&2; exit 1;; esac
  F=$(curl -fsSL "https://pkgs.tailscale.com/stable/?mode=json" | jq -r ".Tarballs.$A")
  curl -fsSL "https://pkgs.tailscale.com/stable/$F" | tar xz --strip-components=1 -C "$TS_DIR" --wildcards '*/tailscale' '*/tailscaled'
  echo "tailscale installed in $TS_DIR"
fi
mkdir -p "$HOME/.config/autostart"
sed "s#@HOME@#$HOME#g; s#@BOOT_SERVICES@#$BOOT_SERVICES#g" "$R/box/autostart/boot-services.desktop" > "$HOME/.config/autostart/boot-services.desktop"
if [ $WITH_CMCC = 1 ]; then bash "$R/keepalive/cmcc/install.sh"
  sed "s#@HOME@#$HOME#g" "$R/box/autostart/cmcc-keepalive.desktop" > "$HOME/.config/autostart/cmcc-keepalive.desktop"; fi
if [ $WITH_ACT = 1 ]; then mkdir -p "$ACTIVITY_DIR"; for f in "$R"/keepalive/box-activity/*.sh; do install -m 755 "$f" "$ACTIVITY_DIR/"; done
  echo "box-activity installed in $ACTIVITY_DIR (start: $ACTIVITY_DIR/ctl.sh start-all)"; fi
# deps + CPA binary (source build by default); BOOT_SERVICES_CHILD=1 -> install only, start below
BOOT_SERVICES_CHILD=1 bash "$CPA_BOOTSTRAP"
if [ $START = 1 ]; then
  if [ -s "$CPA_DIR/config.yaml" ]; then "$CPA_DIR/start-watchdog.sh"; else echo "no $CPA_DIR/config.yaml yet: not starting CPA"; fi
  if [ -s "$TS_DIR/authkey" ] || sudo -n test -s "$TS_DIR/tailscaled.state" 2>/dev/null; then bash "$TS_DIR/ensure-up.sh" || true
  else echo "Tailscale: no auth key yet -> TS_AUTHKEY=... $TS_DIR/set-authkey.sh"; fi
fi
echo "box scheme installed (CPA_DIR=$CPA_DIR, TS_DIR=$TS_DIR). Status: $CPA_DIR/status.sh"
