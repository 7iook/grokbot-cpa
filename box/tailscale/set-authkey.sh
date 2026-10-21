#!/usr/bin/env bash
# Store the Tailscale auth key from $TS_AUTHKEY into $TS_DIR/authkey (root-owned, 600) and bring Tailscale up.
# Never echoes the key. Only needed when there is no valid tailscaled.state yet (first install / lost state).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "${TS_AUTHKEY:-}" ] || { echo "export TS_AUTHKEY first (use a reusable key)" >&2; exit 1; }
mkdir -p "$D"
printf '%s' "$TS_AUTHKEY" | sudo -n install -m 600 -o root -g root /dev/stdin "$KEY"
echo "auth key stored in $KEY"
exec /bin/bash "$D/ensure-up.sh"
