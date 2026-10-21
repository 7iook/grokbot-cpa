#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
mkdir -p "$CPA_DIR/models"; tmp=$(mktemp)
code=$(curl -s -o "$tmp" -w '%{http_code}' -m 15 -H "Authorization: Bearer $(cat "$CPA_DIR/secrets/client-api-key")" "http://$CPA_HOST:$CPA_PORT/v1/models")
if [ "$code" = 200 ] && jq -e . "$tmp" >/dev/null 2>&1; then mv "$tmp" "$CPA_DIR/models/models.json"
  echo "models.json updated: $(jq '(.data // []) | length' "$CPA_DIR/models/models.json") models -> $CPA_DIR/models/models.json"
else rm -f "$tmp"; echo "refresh failed: HTTP $code"; exit 1; fi
