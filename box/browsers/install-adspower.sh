#!/usr/bin/env bash
# Idempotent install of AdsPower Global (Linux x64) into $ADSPOWER_DIR (persistent; extracted .deb, not dpkg -i).
#   install-adspower.sh [--update]   --update = fetch the newest .deb again
# .deb source: $ADSPOWER_URL, or the newest linux-x64-global .deb linked from https://www.adspower.com/download
# (verified 2026-10-21: 8.9.23). Profiles/data stay in ~/.config/adspower_global. Launch: $ADSPOWER_DIR/adspower
set -euo pipefail
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"
DEST=${ADSPOWER_DIR:-$HOME/adspower}; ROOT="$DEST/root"; APPDIR="$ROOT/opt/AdsPower Global"; DL="$DEST/deb"
mkdir -p "$DEST" "$DL"
DEB=$(ls -1 "$DL"/AdsPower-Global-*-x64.deb 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$DEB" ] || [ "${1:-}" = --update ]; then
  URL=${ADSPOWER_URL:-$(timeout 30 curl -sL -A "Mozilla/5.0" https://www.adspower.com/download | grep -oE 'https://version\.adspower\.net/software/linux-x64-global/[^"'"'"' ]+\.deb' | sort -uV | tail -1)}
  [ -n "$URL" ] || { echo "could not find the AdsPower .deb URL; set ADSPOWER_URL in box.env" >&2; exit 1; }
  NEW="$DL/$(basename "$URL")"; [ -f "$NEW" ] || { timeout 900 curl -fL -o "$NEW.part" "$URL" && mv -f "$NEW.part" "$NEW"; }
  DEB="$NEW"
fi
VER=$(dpkg-deb -f "$DEB" Version)
if [ ! -x "$APPDIR/adspower_global" ] || [ "$(cat "$DEST/VERSION" 2>/dev/null)" != "$VER" ]; then
  pgrep -f "$APPDIR/adspower_global" >/dev/null && { echo "AdsPower is running; close it first" >&2; exit 1; }
  rm -rf "$ROOT.new"; mkdir -p "$ROOT.new"; dpkg-deb -x "$DEB" "$ROOT.new"; rm -rf "$ROOT"; mv "$ROOT.new" "$ROOT"
  echo "$VER" > "$DEST/VERSION"; echo "extracted AdsPower $VER"
fi
chmod 0755 "$APPDIR/chrome-sandbox" 2>/dev/null || true
cat > "$DEST/adspower" <<WRAP
#!/bin/bash
# AdsPower Global launcher. --disable-http2 is required on the box (login fails without it).
BIN="$APPDIR/adspower_global"
[ -x "\$BIN" ] || { echo "AdsPower missing; run install-adspower.sh" >&2; exit 1; }
export DISPLAY="\${DISPLAY:-:1}"
exec "\$BIN" --disable-http2 --no-sandbox "\$@"
WRAP
chmod +x "$DEST/adspower"
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/adspower_global.desktop" <<DESK
[Desktop Entry]
Name=AdsPower Global
Exec=$DEST/adspower %U
Terminal=false
Type=Application
Icon=$ROOT/usr/share/icons/hicolor/256x256/apps/adspower_global.png
StartupWMClass=AdsPower Global
MimeType=x-scheme-handler/adsPowerGlobal;
Categories=Utility;
DESK
echo "AdsPower $VER ready: $DEST/adspower"
