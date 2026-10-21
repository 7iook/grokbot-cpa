#!/usr/bin/env bash
# Cloudflare named tunnel for CPA (idempotent). Default exposure path.
#   cf-setup.sh login    start `cloudflared tunnel login`, print the authorize URL, keep waiting in the background
#                        (the cert is saved to $CPA_DIR/secrets/cf-cert.pem once the user approves)
#   cf-setup.sh status   cert present? tunnel/creds/config present?
#   cf-setup.sh [setup]  (needs cert + CF_HOSTNAME) reuse-or-create tunnel $CF_TUNNEL, write creds JSON,
#                        route DNS CF_HOSTNAME -> tunnel, write cloudflared/config.yml, restart the tunnel.
# Alternative without login: CF_TUNNEL_CREDENTIALS_FILE=<id>.json set-tunnel-creds.sh
# Never prints the cert or credentials.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
CERT="$CPA_DIR/secrets/cf-cert.pem"; CFV=${CF_VERSION:-2026.10.0}; LOGF="$LOG_DIR/cf-login.log"
mkdir -p "$CPA_DIR/secrets" "$CPA_DIR/cloudflared" "$LOG_DIR"; chmod 700 "$CPA_DIR/secrets" "$CPA_DIR/cloudflared"
export TUNNEL_ORIGIN_CERT="$CERT"
ensure_cf() {
  [ -x "$CF_BIN" ] && return 0
  local a; case "$(uname -m)" in x86_64) a=amd64;; aarch64|arm64) a=arm64;; *) echo "unsupported arch" >&2; return 1;; esac
  mkdir -p "${CF_BIN%/*}"
  timeout 180 curl -fsSL -o "$CF_BIN.tmp" "https://github.com/cloudflare/cloudflared/releases/download/$CFV/cloudflared-linux-$a" &&
    chmod 755 "$CF_BIN.tmp" && mv -f "$CF_BIN.tmp" "$CF_BIN" && echo "cloudflared $CFV installed"
}
cfd() { timeout "${T:-60}" "$CF_BIN" --origincert "$CERT" "$@"; }
case "${1:-setup}" in
  login)
    ensure_cf || exit 1
    [ -s "$CERT" ] && { echo "already authorized ($CERT)"; exit 0; }
    rm -f "$HOME/.cloudflared/cert.pem"; : > "$LOGF"
    # cloudflared prints the URL, then polls until the browser authorization completes (up to ~15 min)
    setsid -f bash -c 'timeout 1200 "$1" tunnel login >>"$2" 2>&1; [ -s "$HOME/.cloudflared/cert.pem" ] &&
      install -m 600 "$HOME/.cloudflared/cert.pem" "$3" && rm -f "$HOME/.cloudflared/cert.pem"' cf-login "$CF_BIN" "$LOGF" "$CERT" </dev/null >/dev/null 2>&1
    for _ in $(seq 1 30); do u=$(grep -oE 'https://dash\.cloudflare\.com/argotunnel[^[:space:]]+' "$LOGF" | head -1); [ -n "$u" ] && break; sleep 1; done
    [ -n "${u:-}" ] || { echo "no login URL yet; see $LOGF" >&2; exit 1; }
    echo "Open this URL, log in to Cloudflare and authorize the zone of $CF_HOSTNAME:"; echo "$u"
    echo "Then run: $0 setup   (waits for the cert)" ;;
  status)
    [ -s "$CERT" ] && echo "cert: present" || echo "cert: MISSING (run: $0 login)"
    [ -f "$CF_CONFIG" ] && echo "config: $(grep -E '^tunnel:|hostname:' "$CF_CONFIG" | tr -s ' ' | tr '\n' ' ')" || echo "config: missing"
    tunnel_running && echo "tunnel: running" || echo "tunnel: not running" ;;
  setup)
    ensure_cf || exit 1
    [ -n "$CF_HOSTNAME" ] || { echo "set CF_HOSTNAME in box.env" >&2; exit 1; }
    for _ in $(seq 1 "${CF_CERT_WAIT:-300}"); do [ -s "$CERT" ] && break; sleep 1; done
    [ -s "$CERT" ] || { echo "no Cloudflare cert yet: run '$0 login' and approve the URL" >&2; exit 1; }
    id=$(cfd tunnel list -o json -n "$CF_TUNNEL" 2>/dev/null | jq -r --arg n "$CF_TUNNEL" '[.[] | select(.name==$n and (.deleted_at==null or .deleted_at=="0001-01-01T00:00:00Z"))][0].id // empty')
    if [ -z "$id" ]; then
      tmp="$CPA_DIR/cloudflared/.new.json"
      cfd tunnel create --credentials-file "$tmp" "$CF_TUNNEL" >/dev/null || { echo "tunnel create failed" >&2; exit 1; }
      id=$(jq -r .TunnelID "$tmp"); mv -f "$tmp" "$CPA_DIR/cloudflared/$id.json"; echo "created tunnel $CF_TUNNEL ($id)"
    else echo "reusing tunnel $CF_TUNNEL ($id)"; fi
    cred="$CPA_DIR/cloudflared/$id.json"
    if [ ! -s "$cred" ]; then cfd tunnel token --cred-file "$cred" "$id" >/dev/null || { echo "could not fetch credentials for $id" >&2; exit 1; }; fi
    chmod 600 "$cred"
    cfd tunnel route dns --overwrite-dns "$id" "$CF_HOSTNAME" 2>&1 | grep -vi token | tail -1
    CF_TUNNEL_CREDENTIALS_FILE="$cred" "$CPA_DIR/set-tunnel-creds.sh" || exit 1
    "$CPA_DIR/restart-tunnel.sh" || true
    for _ in $(seq 1 30); do tunnel_ready && break; sleep 2; done
    tunnel_ready && echo "tunnel connected" || echo "tunnel not ready yet; see $LOG_DIR/tunnel.log"
    c=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$CF_HOSTNAME/v1/models"); echo "public https://$CF_HOSTNAME/v1/models -> HTTP $c" ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
