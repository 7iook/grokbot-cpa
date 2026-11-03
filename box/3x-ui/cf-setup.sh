#!/usr/bin/env bash
# Cloudflare named tunnel for 3x-ui (idempotent). Its own tunnel ($XUI_CF_TUNNEL, default grokbot-3xui), separate from CPA's.
#   cf-setup.sh [setup]  reuse-or-create the tunnel with the Cloudflare cert CPA's cf-setup.sh saved
#                        ($CPA_DIR/secrets/cf-cert.pem; run `~/cli-proxy-api/cf-setup.sh login` first), route DNS for
#                        XUI_CF_HOSTNAME / XUI_SUB_HOSTNAME / XUI_NODE_HOSTNAME, render cloudflared/config.yml, restart.
#   cf-setup.sh creds <tunnel-id>.json   use an existing credentials JSON instead (no cert; DNS routes are up to you)
#   cf-setup.sh status
# Never prints the cert or credentials.
set -uo pipefail
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$R/env.sh"
CPA_DIR=${CPA_DIR:-$HOME/cli-proxy-api}; CERT=${XUI_CF_CERT:-$CPA_DIR/secrets/cf-cert.pem}; CFV=${CF_VERSION:-2026.10.0}
TMPL=$R/cloudflared/config.yml.tmpl
mkdir -p "$R/cloudflared" "$R/bin" "$XUI_LOG_FOLDER"; chmod 700 "$R/cloudflared"
ensure_cf() {
  [ -x "$XUI_CF_BIN" ] && return 0
  if [ -x "$CPA_DIR/bin/cloudflared" ]; then install -m 755 "$CPA_DIR/bin/cloudflared" "$XUI_CF_BIN"; return; fi
  local a; case "$(uname -m)" in x86_64) a=amd64;; aarch64|arm64) a=arm64;; *) echo "unsupported arch" >&2; return 1;; esac
  timeout 180 curl -fsSL -o "$XUI_CF_BIN.tmp" "https://github.com/cloudflare/cloudflared/releases/download/$CFV/cloudflared-linux-$a" &&
    chmod 755 "$XUI_CF_BIN.tmp" && mv -f "$XUI_CF_BIN.tmp" "$XUI_CF_BIN" && echo "cloudflared $CFV installed"
}
cfd() { timeout "${T:-60}" "$XUI_CF_BIN" --origincert "$CERT" "$@"; }
render() { # $1 tunnel id, $2 creds file
  local t; t=$(cat "$TMPL") || { echo "missing $TMPL (re-run box/3x-ui/install.sh)" >&2; return 1; }
  t=${t//@TUNNEL_ID@/$1}; t=${t//@CRED_FILE@/$2}
  t=${t//@PANEL_PORT@/$XUI_PANEL_PORT}; t=${t//@SUB_PORT@/$XUI_SUB_PORT}; t=${t//@NODE_PORT@/$XUI_NODE_PORT}
  t=${t//@PANEL_HOSTNAME@/$XUI_CF_HOSTNAME}; t=${t//@SUB_HOSTNAME@/$XUI_SUB_HOSTNAME}; t=${t//@NODE_HOSTNAME@/$XUI_NODE_HOSTNAME}
  # drop ingress pairs with an empty hostname
  printf '%s\n' "$t" | awk '/^  - hostname: *$/ { skip = 1; next } skip { skip = 0; next } { print }' > "$XUI_CF_CONFIG.tmp" &&
    mv -f "$XUI_CF_CONFIG.tmp" "$XUI_CF_CONFIG" && echo "wrote $XUI_CF_CONFIG"
}
finish() {
  rm -f "$R/.tunnel-disabled"; "$R/tunnel.sh" restart || true
  for _ in $(seq 1 30); do curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$XUI_CF_METRICS/ready" | grep -q 200 && break; sleep 2; done
  for h in "$XUI_CF_HOSTNAME" "$XUI_SUB_HOSTNAME" "$XUI_NODE_HOSTNAME"; do [ -n "$h" ] || continue
    echo "public https://$h/ -> HTTP $(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$h/")  (sub/node answer 404 on /: OK)"; done
}
case "${1:-setup}" in
  status)
    [ -s "$CERT" ] && echo "cert: present ($CERT)" || echo "cert: missing (~/cli-proxy-api/cf-setup.sh login)"
    [ -f "$XUI_CF_CONFIG" ] && echo "config: $(grep -E '^tunnel:|hostname:' "$XUI_CF_CONFIG" | tr -s ' ' | tr '\n' ' ')" || echo "config: missing"
    "$R/tunnel.sh" status ;;
  creds)
    f=${2:-}; [ -s "$f" ] || { echo "usage: $0 creds <tunnel-id>.json" >&2; exit 2; }
    id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["TunnelID"])' "$f") || { echo "not a tunnel credentials JSON" >&2; exit 1; }
    ensure_cf || exit 1
    install -m 600 "$f" "$R/cloudflared/$id.json"; render "$id" "$R/cloudflared/$id.json" && finish ;;
  setup)
    ensure_cf || exit 1
    [ -n "$XUI_CF_HOSTNAME$XUI_SUB_HOSTNAME$XUI_NODE_HOSTNAME" ] || { echo "set XUI_CF_HOSTNAME / XUI_SUB_HOSTNAME / XUI_NODE_HOSTNAME in box.env" >&2; exit 1; }
    [ -s "$CERT" ] || { echo "no Cloudflare cert at $CERT: run ~/cli-proxy-api/cf-setup.sh login and approve the URL" >&2; exit 1; }
    id=$(cfd tunnel list -o json -n "$XUI_CF_TUNNEL" 2>/dev/null | python3 -c 'import json,sys
n=sys.argv[1]; L=[t for t in json.load(sys.stdin) or [] if t.get("name")==n and t.get("deleted_at") in (None,"","0001-01-01T00:00:00Z")]
print(L[0]["id"] if L else "")' "$XUI_CF_TUNNEL")
    if [ -z "$id" ]; then
      tmp="$R/cloudflared/.new.json"
      cfd tunnel create --credentials-file "$tmp" "$XUI_CF_TUNNEL" >/dev/null || { echo "tunnel create failed" >&2; exit 1; }
      id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["TunnelID"])' "$tmp"); mv -f "$tmp" "$R/cloudflared/$id.json"
      echo "created tunnel $XUI_CF_TUNNEL ($id)"
    else echo "reusing tunnel $XUI_CF_TUNNEL ($id)"; fi
    cred="$R/cloudflared/$id.json"
    [ -s "$cred" ] || cfd tunnel token --cred-file "$cred" "$id" >/dev/null || { echo "could not fetch credentials for $id" >&2; exit 1; }
    chmod 600 "$cred"
    for h in "$XUI_CF_HOSTNAME" "$XUI_SUB_HOSTNAME" "$XUI_NODE_HOSTNAME"; do [ -n "$h" ] || continue
      cfd tunnel route dns --overwrite-dns "$id" "$h" 2>&1 | grep -vi token | tail -1; done
    render "$id" "$cred" && finish ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
