#!/usr/bin/env bash
# grokbot-cpa self-check: PASS/FAIL per component + summary. Read-only (starts nothing), never prints secrets.
#   selfcheck.sh [--no-tunnel] [--no-tailscale] [--no-browsers] [--no-cmcc] [--no-activity] [--no-plugins]
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"
PERSIST_ROOT=${PERSIST_ROOT:-$HOME}; CPA_DIR=${CPA_DIR:-$PERSIST_ROOT/cli-proxy-api}; TS_DIR=${TS_DIR:-$PERSIST_ROOT/tailscale}
. "$CPA_DIR/common.sh" 2>/dev/null || { echo "FAIL  cpa: $CPA_DIR/common.sh missing (run install.sh)"; exit 1; }
declare -A SKIP=(); for a in "$@"; do SKIP[${a#--no-}]=1; done
P=0; F=0; W=0
ok()   { echo "PASS  $*"; P=$((P+1)); }
bad()  { echo "FAIL  $*"; F=$((F+1)); }
warn() { echo "WARN  $*"; W=$((W+1)); }
chk()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
code() { curl -s -o /dev/null -m "${3:-10}" -w '%{http_code}' ${2:+-H "Authorization: Bearer $2"} "$1"; }
KEY=$(cat "$CPA_DIR/secrets/client-api-key" 2>/dev/null); MS=$(cat "$CPA_DIR/secrets/management-secret" 2>/dev/null)

echo "== persistence (PERSIST_ROOT=$PERSIST_ROOT)"
for v in CPA_DIR TS_DIR BOOT_SERVICES CPA_BOOTSTRAP ADSPOWER_DIR ROXY_DIR ACTIVITY_DIR CMCC_DIR; do
  p="${!v:-}"; [ -n "$p" ] || continue
  case "$p" in "$PERSIST_ROOT"/*) ok "$v under PERSIST_ROOT";; *) bad "$v=$p is outside PERSIST_ROOT (lost on reboot)";; esac
done
for b in "$CPA_BIN" "$CF_BIN" "$TS_DIR/tailscaled"; do case "$(readlink -f "$b" 2>/dev/null || echo "$b")" in "$PERSIST_ROOT"/*) ;; *) bad "binary $b not under PERSIST_ROOT";; esac; done
miss=""; for p in ${BOOT_APT_PKGS:-}; do dpkg -s "$p" >/dev/null 2>&1 || miss="$miss $p"; done
[ -z "$miss" ] && ok "boot apt packages present" || warn "apt packages missing (boot-services.sh reinstalls):$miss"

echo "== CPA"
chk "cpa process running" cpa_running
c=$(code "http://$CPA_HOST:$CPA_PORT/v1/models" "$KEY"); [ "$c" = 200 ] && ok "local /v1/models HTTP 200" || bad "local /v1/models HTTP $c"
c=$(code "http://$CPA_HOST:$CPA_PORT/v0/management/plugins" "$MS"); [ "$c" = 200 ] && ok "management API HTTP 200" || bad "management API HTTP $c"
n=$(find "$CPA_DIR/auths" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l); [ "$n" -gt 0 ] && ok "upstream auth files: $n" || warn "no upstream accounts yet (claude-login.sh start)"
chk "secrets dir mode 700" test "$(stat -c %a "$CPA_DIR/secrets" 2>/dev/null)" = 700
if [ -z "${SKIP[plugins]:-}" ]; then
  pl=$(curl -s -m 10 -H "Authorization: Bearer $MS" "http://$CPA_HOST:$CPA_PORT/v0/management/plugins")
  for id in ${CPA_PLUGINS:-claude-keep-rolling cpa-key-billing usage-dashboard-zduu} claude-cache-keepalive; do id=${id%@*}
    e=$(printf '%s' "$pl" | jq -r --arg id "$id" '[.. | objects | select(.id? == $id)][0] | if . == null then "missing" else (.enabled // "unknown" | tostring) end' 2>/dev/null)
    case "$e" in true) ok "plugin $id enabled";; missing|"") bad "plugin $id not installed";; *) bad "plugin $id enabled=$e";; esac
  done
  printf '%s' "$pl" | jq -e '[.. | objects | select(.id? == "lamplighter")] | length == 0' >/dev/null 2>&1 && ok "lamplighter not installed" || warn "lamplighter is installed"
fi

echo "== watchdogs + boot"
chk "CPA watchdog running" wd_running
chk "CPA watchdog heartbeat < 120s" test "$(file_age "$WD_HEARTBEAT")" -lt 120
chk "boot-services.sh present" test -x "$BOOT_SERVICES"
chk "autostart boot-services.desktop" grep -q "$BOOT_SERVICES" "$HOME/.config/autostart/boot-services.desktop"

if [ -z "${SKIP[tunnel]:-}" ]; then echo "== Cloudflare tunnel"
  chk "cloudflared config ($CF_CONFIG)" test -s "$CF_CONFIG"
  chk "tunnel process running" tunnel_running
  chk "tunnel connection registered" tunnel_ready
  if [ -n "${CF_HOSTNAME:-}" ]; then c=$(code "https://$CF_HOSTNAME/v1/models" "$KEY" 20)
    case "$c" in 200|401) ok "public https://$CF_HOSTNAME/v1/models HTTP $c";; *) bad "public https://$CF_HOSTNAME/v1/models HTTP $c";; esac
  else bad "CF_HOSTNAME not set"; fi
fi
if [ -z "${SKIP[tailscale]:-}" ]; then echo "== Tailscale"
  j=$(sudo -n timeout 10 "$TS_DIR/tailscale" --socket="$TS_DIR/tailscaled.sock" status --json 2>/dev/null)
  st=$(printf '%s' "$j" | jq -r .BackendState 2>/dev/null); [ "$st" = Running ] && ok "tailscale Running ($(printf '%s' "$j" | jq -r '.Self.HostName + " " + (.TailscaleIPs[0] // "-")'))" || bad "tailscale state: ${st:-down}"
  s=$(sudo -n timeout 10 "$TS_DIR/tailscale" --socket="$TS_DIR/tailscaled.sock" debug prefs 2>/dev/null | jq -r .RunSSH 2>/dev/null)
  if [ "${TS_SSH:-1}" = 1 ]; then [ "$s" = true ] && ok "tailscale SSH enabled" || bad "tailscale SSH not enabled"; fi
  chk "tailscale watchdog running" lock_held "$TS_WD_LOCK"
  chk "tailscale state persisted" sudo -n test -s "$TS_DIR/tailscaled.state"
fi
if [ -z "${SKIP[cmcc]:-}" ]; then echo "== keepalives"
  chk "cmcc WebUI running" pgrep -f cmcc_cloud_alive.webui
  chk "autostart cmcc-keepalive.desktop" test -f "$HOME/.config/autostart/cmcc-keepalive.desktop"
fi
[ -z "${SKIP[activity]:-}" ] && { chk "box-activity monitor running" pgrep -f "${ACTIVITY_DIR:-x}/monitor.sh"; chk "box-activity browse loop running" pgrep -f "${ACTIVITY_DIR:-x}/browse-loop.sh"; }
if [ -z "${SKIP[browsers]:-}" ]; then echo "== browsers"
  chk "AdsPower installed ($(cat "${ADSPOWER_DIR:-x}/VERSION" 2>/dev/null))" test -x "${ADSPOWER_DIR:-x}/root/opt/AdsPower Global/adspower_global"
  chk "RoxyBrowser installed ($(cat "${ROXY_DIR:-x}/VERSION" 2>/dev/null))" test -x "${ROXY_DIR:-x}/roxybrowser"
fi
echo "== SUMMARY: $P passed, $F failed, $W warnings"
[ $F = 0 ] && { echo "SELFCHECK: PASS"; exit 0; } || { echo "SELFCHECK: FAIL"; exit 1; }
