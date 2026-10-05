#!/usr/bin/env bash
# Hit the public URL once and log timestamp + HTTP status (keeps the tunnel path warm). Never hits localhost.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
LOG="$DIR/logs/keepalive.log"; TS="$(date '+%F %T %Z')"
URL="$(public_url)"
case "$URL" in
  ""|http://localhost*|https://localhost*|http://127.*|https://127.*|http://0.0.0.0*|https://0.0.0.0*|http://\[::1\]*|https://\[::1\]*)
    echo "$TS skip: no public URL ($URL)" >> "$LOG"; exit 0 ;;
esac
echo "$TS $URL HTTP $(http_code "$URL/" 30)" >> "$LOG"
