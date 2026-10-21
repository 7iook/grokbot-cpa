#!/usr/bin/env bash
# Install named-tunnel credentials and write cloudflared/config.yml (never echoes the credentials).
#   CF_TUNNEL_CREDENTIALS_FILE=/path/<tunnel-id>.json set-tunnel-creds.sh   (from `cloudflared tunnel create`)
#   or CF_TUNNEL_CREDENTIALS='<json>' set-tunnel-creds.sh
# Uses CF_TUNNEL / CF_HOSTNAME / CPA_PORT from box.env.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ -n "$CF_HOSTNAME" ] || { echo "set CF_HOSTNAME in box.env first" >&2; exit 1; }
mkdir -p "$CPA_DIR/cloudflared"; chmod 700 "$CPA_DIR/cloudflared"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if [ -n "${CF_TUNNEL_CREDENTIALS_FILE:-}" ]; then cat "$CF_TUNNEL_CREDENTIALS_FILE" > "$tmp"
elif [ -n "${CF_TUNNEL_CREDENTIALS:-}" ]; then printf '%s' "$CF_TUNNEL_CREDENTIALS" > "$tmp"
else echo "provide CF_TUNNEL_CREDENTIALS_FILE or CF_TUNNEL_CREDENTIALS" >&2; exit 1; fi
id=$(jq -r '.TunnelID // empty' "$tmp"); [ -n "$id" ] || { echo "credentials JSON has no TunnelID" >&2; exit 1; }
install -m 600 "$tmp" "$CPA_DIR/cloudflared/$id.json"
cat > "$CF_CONFIG" <<YML
tunnel: $id
credentials-file: $CPA_DIR/cloudflared/$id.json
protocol: http2
no-autoupdate: true
ingress:
  - hostname: $CF_HOSTNAME
    service: http://127.0.0.1:$CPA_PORT
  - service: http_status:404
YML
echo "tunnel $id configured for $CF_HOSTNAME -> 127.0.0.1:$CPA_PORT (restart: restart-tunnel.sh)"
