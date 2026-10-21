#!/usr/bin/env bash
# Idempotent install of RoxyBrowser (Linux x64) into $ROXY_DIR (persistent; extracted .deb, not dpkg -i).
#   install-roxy.sh [--update]
# .deb source: $ROXY_URL (default: official https://dl.roxybrowser.com/app-download/Linux-64-latest, which redirects to
# RoxyBrowser_x64_<ver>.deb; verified 2026-10-21 -> 4.0.8). Profiles/data stay in ~/.config/RoxyBrowser. Launch: $ROXY_DIR/roxybrowser
set -euo pipefail
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"
DEST=${ROXY_DIR:-$HOME/roxybrowser}; ROOT="$DEST/root"; DL="$DEST/deb"
URL=${ROXY_URL:-https://dl.roxybrowser.com/app-download/Linux-64-latest}
mkdir -p "$DEST" "$DL"
DEB=$(ls -1 "$DL"/RoxyBrowser_x64_*.deb 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$DEB" ] || [ "${1:-}" = --update ]; then
  final=$(timeout 60 curl -sIL -o /dev/null -w '%{url_effective}' -A "Mozilla/5.0" "$URL")
  name=$(basename "${final%%\?*}"); case "$name" in *.deb) ;; *) name=RoxyBrowser_x64_latest.deb;; esac
  NEW="$DL/$name"; [ -f "$NEW" ] || { timeout 900 curl -fL -A "Mozilla/5.0" -o "$NEW.part" "$URL" && mv -f "$NEW.part" "$NEW"; }
  DEB="$NEW"
fi
VER=$(dpkg-deb -f "$DEB" Version)
BIN="$ROOT/opt/RoxyBrowser/roxybrowser"
if [ ! -x "$BIN" ] || [ "$(cat "$DEST/VERSION" 2>/dev/null)" != "$VER" ]; then
  pgrep -f "$BIN" >/dev/null && { echo "RoxyBrowser is running; close it first" >&2; exit 1; }
  rm -rf "$ROOT.new"; mkdir -p "$ROOT.new"; dpkg-deb -x "$DEB" "$ROOT.new"; rm -rf "$ROOT"; mv "$ROOT.new" "$ROOT"
  echo "$VER" > "$DEST/VERSION"; echo "extracted RoxyBrowser $VER"
fi
[ -x "$BIN" ] || BIN=$(find "$ROOT/opt" -maxdepth 2 -type f -name roxybrowser -perm -u+x | head -1)
cat > "$DEST/roxybrowser" <<WRAP
#!/bin/bash
# RoxyBrowser launcher (extracted .deb under $ROOT)
export DISPLAY="\${DISPLAY:-:1}"
exec "$BIN" --no-sandbox --disable-setuid-sandbox "\$@"
WRAP
chmod +x "$DEST/roxybrowser"
mkdir -p "$HOME/.local/share/applications"
d=$(find "$ROOT/usr/share/applications" -name '*.desktop' 2>/dev/null | head -1)
if [ -n "$d" ]; then sed -E "s#^Exec=.*#Exec=$DEST/roxybrowser %U#" "$d" > "$HOME/.local/share/applications/roxybrowser.desktop"; fi
echo "RoxyBrowser $VER ready: $DEST/roxybrowser"
