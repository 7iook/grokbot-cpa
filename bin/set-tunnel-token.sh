#!/usr/bin/env bash
# Save the Cloudflare named-tunnel token to .tunnel-token (chmod 600). The token is never printed.
# Usage (pick one):
#   CF_TUNNEL_TOKEN=... ./set-tunnel-token.sh        # e.g. from a bot's secure secret input
#   ./set-tunnel-token.sh /path/to/file              # file containing the token
#   ./set-tunnel-token.sh -  < file                  # stdin
# A whole "cloudflared service install eyJ..." / "tunnel run --token eyJ..." line is accepted too;
# only the eyJ... part is kept.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
if [[ $# -ge 1 && "$1" == "-" ]]; then RAW="$(cat)"
elif [[ $# -ge 1 ]]; then [[ -r "$1" ]] || { echo "ERROR: cannot read $1" >&2; exit 1; }; RAW="$(cat "$1")"
elif [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then RAW="$CF_TUNNEL_TOKEN"
else echo "ERROR: set CF_TUNNEL_TOKEN or pass a file (or - for stdin)" >&2; exit 1; fi
TOKEN="$(printf '%s' "$RAW" | tr -s '[:space:]' '\n' | grep -m1 -oE 'eyJ[A-Za-z0-9_=+/-]+' || true)"
unset RAW
if [[ ${#TOKEN} -lt 50 ]]; then echo "ERROR: that does not look like a tunnel token (expected eyJ..., usually 150+ chars)" >&2; exit 1; fi
# The token is base64(JSON {"a": account tag, "t": tunnel id, "s": secret}). Show only the tunnel id.
pad="$TOKEN"; while (( ${#pad} % 4 )); do pad+="="; done
TID="$(printf '%s' "$pad" | tr '_-' '/+' | base64 -d 2>/dev/null | grep -oE '"t" *: *"[0-9a-f-]{36}"' | grep -oE '[0-9a-f-]{36}' || true)"
[[ -n "$TID" ]] || { echo "ERROR: token did not decode to a tunnel id; copy it again from the Cloudflare dashboard" >&2; exit 1; }
( umask 077; printf '%s' "$TOKEN" > "$DIR/.tunnel-token.tmp" ) && mv -f "$DIR/.tunnel-token.tmp" "$DIR/.tunnel-token" && chmod 600 "$DIR/.tunnel-token"
unset TOKEN pad
echo "Saved $DIR/.tunnel-token (chmod 600) for tunnel id $TID."
