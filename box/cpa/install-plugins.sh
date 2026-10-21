#!/usr/bin/env bash
# Install CPA plugins (idempotent). Needs CPA running with plugins.enabled=true (templates/config.yaml.tmpl).
#  - Store plugins via the management API: POST /v0/management/plugin-store/<id>/install?version=<v>
#    (auth: $CPA_DIR/secrets/management-secret; extra registries come from plugins.store-sources in config.yaml).
#  - 缓存保活 (claude-cache-keepalive) is not in any store: built from source (CGO, needs gcc + Go) and copied
#    into plugins/<os>/<arch>/.
# List: CPA_PLUGINS in box.env, entries "id@version" (version optional = latest). Lamplighter is intentionally absent.
#   install-plugins.sh [--force]   --force reinstalls plugins that are already present
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
CPA_PLUGINS=${CPA_PLUGINS:-"claude-keep-rolling@0.2.4 cpa-key-billing@1.4.0 usage-dashboard-zduu@2.7.5"}
CACHE_KEEPALIVE=${CACHE_KEEPALIVE:-1}
CACHE_KEEPALIVE_REPO=${CACHE_KEEPALIVE_REPO:-https://github.com/Banben07/cpa_claude_cache_keep.git}
CACHE_KEEPALIVE_REF=${CACHE_KEEPALIVE_REF:-9b8637d}   # 0.8.12
FORCE=0; [ "${1:-}" = --force ] && FORCE=1
M="http://$CPA_HOST:$CPA_PORT/v0/management"
SEC="$CPA_DIR/secrets/management-secret"
[ -s "$SEC" ] || { echo "missing $SEC (plaintext management secret)" >&2; exit 1; }
api() { curl -s -m "${T:-30}" -H "Authorization: Bearer $(cat "$SEC")" -H 'Content-Type: application/json' "$@"; }
for _ in $(seq 1 30); do port_open && break; sleep 1; done
port_open || { echo "CPA is not listening on $CPA_PORT; start it first (start-watchdog.sh)" >&2; exit 1; }
grep -qE '^plugins:' "$CPA_CONFIG" || echo "WARNING: no plugins: block in $CPA_CONFIG (needs enabled: true + store-sources), see templates/config.yaml.tmpl"
have() { api "$M/plugins" | jq -e --arg id "$1" '[.. | objects | select(.id? == $id)] | length > 0' >/dev/null 2>&1; }
enable() { api -X PATCH -d '{"enabled":true}' "$M/plugins/$1/enabled" -o /dev/null -w '%{http_code}'; }
rc=0
for p in $CPA_PLUGINS; do
  id=${p%@*}; ver=""; [ "$p" != "$id" ] && ver=${p#*@}
  if [ $FORCE = 0 ] && have "$id"; then echo "plugin $id: already installed"; continue; fi
  q=""; [ -n "$ver" ] && q="?version=$ver"
  out=$(T=300 api -X POST "$M/plugin-store/$id/install$q" -w ' HTTP%{http_code}')
  case "$out" in *HTTP2??) echo "plugin $id${ver:+ $ver}: installed (enable: HTTP $(enable "$id"))";;
    *) echo "plugin $id: install FAILED: ${out: -300}"; rc=1;; esac
done
if [ "$CACHE_KEEPALIVE" = 1 ]; then
  id=claude-cache-keepalive; os=linux; arch=$(uname -m); case "$arch" in x86_64) arch=amd64;; aarch64) arch=arm64;; esac
  dst="$CPA_DIR/plugins/$os/$arch/$id.so"
  if [ $FORCE = 0 ] && [ -s "$dst" ]; then echo "plugin $id: already present ($dst)"
  else
    GO=$(command -v go || echo "$HOME/.local/go/bin/go"); src="$CPA_DIR/src/cpa_claude_cache_keep"
    command -v gcc >/dev/null || { sudo apt-get install -y -qq gcc >/dev/null 2>&1; }
    if [ ! -x "$GO" ] || ! command -v gcc >/dev/null; then echo "plugin $id: FAILED (needs Go and gcc)"; rc=1
    else
      { [ -d "$src/.git" ] || timeout 120 git clone -q "$CACHE_KEEPALIVE_REPO" "$src"; } &&
      timeout 120 git -C "$src" fetch -q origin && git -C "$src" checkout -q "$CACHE_KEEPALIVE_REF" &&
      (cd "$src" && CGO_ENABLED=1 GOOS=$os GOARCH=$arch "$GO" build -buildvcs=false -buildmode=c-shared -o "dist/$os/$arch/$id.so" .) &&
      mkdir -p "${dst%/*}" && install -m 755 "$src/dist/$os/$arch/$id.so" "$dst" &&
      echo "plugin $id: built from $CACHE_KEEPALIVE_REPO@$CACHE_KEEPALIVE_REF -> $dst" || { echo "plugin $id: build FAILED"; rc=1; }
    fi
  fi
  [ -s "$dst" ] && echo "plugin $id: enable HTTP $(enable "$id") (a CPA restart may be needed to load a new .so: stop.sh)"
fi
exit $rc
