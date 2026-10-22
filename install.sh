#!/usr/bin/env bash
# grokbot-cpa installer: EVERYTHING is installed by default (idempotent; keeps config.yaml, secrets, state).
#
#   [CF_HOSTNAME=api.example.com] [TS_AUTHKEY=...] ./install.sh [--no-tunnel] [--no-tailscale] [--no-plugins]
#        [--no-browsers] [--no-cmcc] [--no-activity] [--no-start] [--reset-config]
#
# Order: box/install-box.sh (persistent layout under PERSIST_ROOT, apt deps, CPA built from 7iook/CLIProxyAPI
# feat/claude-setup-token-quota, Tailscale binaries, boot autostart, keepalives, AdsPower + RoxyBrowser)
#   -> config.yaml + secrets/{client-api-key,management-secret} -> CPA watchdog -> plugins (install-plugins.sh)
#   -> Cloudflare tunnel (cf-setup.sh: prints a login URL if not authorized yet, then creates/reuses the tunnel)
#   -> Tailscale with SSH (TS_AUTHKEY env -> set-authkey.sh, or existing state) -> keepalives -> selfcheck.sh
# Release CPA binary instead of the source build: CPA_BUILD=release CPA_VERSION=v8.0.29 ./install.sh
# Entry point for bots: AGENTS.md / skills/grokbot-setup/SKILL.md
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGS=(); RESET=0; PLUGINS=1; TUNNEL=1; TSC=1; NOSKIP=()
for a in "$@"; do case "$a" in --reset-config) RESET=1;; --no-plugins) PLUGINS=0; NOSKIP+=("$a");; --no-tunnel) TUNNEL=0; NOSKIP+=("$a");; --no-tailscale) TSC=0; NOSKIP+=("$a");;
  --no-browsers|--no-cmcc|--no-activity) ARGS+=("$a"); NOSKIP+=("$a");; -h|--help) sed -n '2,14p' "$0"; exit 0;; *) ARGS+=("$a");; esac; done
[ "$(uname -s)" = Linux ] || { echo "only Linux is supported" >&2; exit 1; }
for c in curl tar openssl sed; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done
command -v jq >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq jq; } >/dev/null
CFG="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"
bash "$R/box/install-box.sh" --no-start "${ARGS[@]}"
# shellcheck disable=SC1090
. "$CFG"
PERSIST_ROOT=${PERSIST_ROOT:-$HOME}; CF_CONFIG_PATH="$CPA_DIR/cloudflared/config.yml"
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
mkdir -p "$TS_DIR"
if [ $TSC = 0 ]; then touch "$TS_DIR/.watchdog-stopped"; echo "Tailscale skipped (--no-tailscale): $TS_DIR/.watchdog-stopped set, watchdogs will not start it"
else rm -f "$TS_DIR/.watchdog-stopped"; fi
"$CPA_DIR/start-watchdog.sh"
if [ $PLUGINS = 1 ]; then "$CPA_DIR/install-plugins.sh" || echo "WARNING: some plugins failed; re-run $CPA_DIR/install-plugins.sh"; fi
if [ $TUNNEL = 1 ]; then
  if [ -z "${CF_HOSTNAME:-}" ]; then echo "Cloudflare: set CF_HOSTNAME in box.env, then: $CPA_DIR/cf-setup.sh login && $CPA_DIR/cf-setup.sh setup"
  elif [ -s "$CPA_DIR/secrets/cf-cert.pem" ] || [ -s "$CF_CONFIG_PATH" ]; then CF_CERT_WAIT=5 "$CPA_DIR/cf-setup.sh" setup || echo "WARNING: cf-setup failed"
  else "$CPA_DIR/cf-setup.sh" login || true; echo ">>> after the user approved the URL run: $CPA_DIR/cf-setup.sh setup"; fi
fi
if [ $TSC = 1 ]; then
  if [ -n "${TS_AUTHKEY:-}" ] && ! sudo -n test -s "$TS_DIR/tailscaled.state" 2>/dev/null; then TS_AUTHKEY="$TS_AUTHKEY" bash "$TS_DIR/set-authkey.sh" || true
  elif [ -s "$TS_DIR/authkey" ] || sudo -n test -s "$TS_DIR/tailscaled.state" 2>/dev/null; then timeout 150 bash "$TS_DIR/ensure-up.sh" || true
  else echo "Tailscale: TS_AUTHKEY=... $TS_DIR/set-authkey.sh"; fi
fi
"$BOOT_SERVICES" || true   # launches keepalive supervisors (and anything else not yet running)
echo; "$PERSIST_ROOT/grokbot-cpa-bin/selfcheck.sh" "${NOSKIP[@]}" || true
echo; echo "next: $CPA_DIR/claude-login.sh start  |  $PERSIST_ROOT/grokbot-cpa-bin/selfcheck.sh  |  $CPA_DIR/status.sh"
