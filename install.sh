#!/usr/bin/env bash
# grokbot-cpa installer (box scheme). Idempotent; re-running keeps config.yaml and secrets.
#
#   ./install.sh [--with-cmcc] [--with-activity] [--no-start] [--no-plugins] [--reset-config]
#
# What it does:
#   1. box/install-box.sh: scripts -> $CPA_DIR, Tailscale scripts+binaries -> $TS_DIR, boot-services autostart,
#      deps, CPA binary. CPA is BUILT FROM SOURCE by default:
#        CPA_SOURCE_REPO=https://github.com/7iook/CLIProxyAPI.git  CPA_SOURCE_REF=feat/claude-setup-token-quota
#      Official release binary instead:  CPA_BUILD=release CPA_VERSION=v8.0.29 ./install.sh
#   2. config.yaml from templates/config.yaml.tmpl with a new random client API key + management secret
#      (copies in $CPA_DIR/secrets/{client-api-key,management-secret}, mode 600) unless one already exists.
#   3. starts the CPA watchdog (CPA + tunnel) and Tailscale (if an auth key / state exists).
#   4. installs CPA plugins (box/cpa/install-plugins.sh: 缓存保活, Claude Keep Rolling, CPA Key Billing, 用量统计;
#      list in box.env CPA_PLUGINS / CACHE_KEEPALIVE). Skip with --no-plugins.
# Settings live in ~/.config/grokbot-cpa/box.env (see box/box.env.example); env vars override on first run.
# Secrets you provide afterwards (never committed):
#   Tailscale:  TS_AUTHKEY=tskey-auth-... $TS_DIR/set-authkey.sh
#   Tunnel:     CF_HOSTNAME in box.env, then CF_TUNNEL_CREDENTIALS_FILE=<id>.json $CPA_DIR/set-tunnel-creds.sh
#   Claude:     $CPA_DIR/claude-login.sh start
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGS=(); RESET=0; PLUGINS=1
for a in "$@"; do case "$a" in --reset-config) RESET=1;; --no-plugins) PLUGINS=0;; -h|--help) sed -n '2,20p' "$0"; exit 0;; *) ARGS+=("$a");; esac; done
[ "$(uname -s)" = Linux ] || { echo "only Linux is supported" >&2; exit 1; }
for c in curl tar openssl sed; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done
command -v jq >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq jq; } >/dev/null
CFG="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"
bash "$R/box/install-box.sh" --no-start "${ARGS[@]}"
# shellcheck disable=SC1090
. "$CFG"
C="$CPA_DIR/config.yaml"
if [ ! -s "$C" ] || [ $RESET = 1 ]; then
  K="sk-cpa-$(openssl rand -hex 24)"; M="$(openssl rand -hex 24)"
  t="$(cat "$R/templates/config.yaml.tmpl")"
  t="${t//@PORT@/${CPA_PORT:-8317}}"; t="${t//@AUTH_DIR@/$CPA_DIR/auths}"; t="${t//@ALLOW_REMOTE@/${ALLOW_REMOTE:-false}}"
  t="${t//@API_KEY@/$K}"; t="${t//@MGMT_SECRET@/$M}"
  ( umask 077; printf '%s\n' "$t" > "$C"; printf '%s' "$K" > "$CPA_DIR/secrets/client-api-key"; printf '%s' "$M" > "$CPA_DIR/secrets/management-secret" )
  unset K M t; echo "wrote $C (client key: $CPA_DIR/secrets/client-api-key)"
else echo "kept existing $C"; fi
[ -s "$CPA_DIR/secrets/client-api-key" ] || echo "WARNING: $CPA_DIR/secrets/client-api-key missing (healthcheck needs it; copy one api-keys entry there, mode 600)"
case " ${ARGS[*]-} " in *" --no-start "*) exit 0;; esac
"$CPA_DIR/start-watchdog.sh"
if [ $PLUGINS = 1 ]; then "$CPA_DIR/install-plugins.sh" || echo "WARNING: some plugins failed; re-run $CPA_DIR/install-plugins.sh"; fi
if [ -s "$TS_DIR/authkey" ] || sudo -n test -s "$TS_DIR/tailscaled.state" 2>/dev/null; then bash "$TS_DIR/ensure-up.sh" || true
else echo "Tailscale: TS_AUTHKEY=... $TS_DIR/set-authkey.sh"; fi
echo; echo "next: $CPA_DIR/claude-login.sh start   |  $CPA_DIR/status.sh   |  $CPA_DIR/healthcheck.sh"
