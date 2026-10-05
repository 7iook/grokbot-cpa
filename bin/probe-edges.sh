#!/usr/bin/env bash
# TLS-probe Cloudflare tunnel edge IPs on :7844 and (with --write) save the working ones,
# split across two connectors, to edge-ips.env. Only used when HOSTS_WORKAROUND=1.
# Falls back to the built-in verified lists if a region has fewer than 2 working IPs.
# Usage: probe-edges.sh [--write]
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
probe() { # prints the IP if a Cloudflare certificate comes back on :7844
  timeout 6 openssl s_client -connect "$1:7844" -servername "$2" </dev/null 2>/dev/null \
    | grep -q 'O *= *CloudFlare' && echo "$1"
}
export -f probe
scan() { # prefix start region-host
  local i; for i in $(seq "$2" 10 254); do echo "$1.$i"; done \
    | xargs -P 16 -I{} bash -c 'probe "$1" "$2"' _ {} "$3" | sort -t. -k4,4n
}
mapfile -t R1 < <(scan 198.41.192 7 region1.v2.argotunnel.com)
mapfile -t R2 < <(scan 198.41.200 3 region2.v2.argotunnel.com)
echo "region1: ${#R1[@]} working IPs; region2: ${#R2[@]} working IPs"
split() { # max list... -> "c1|c2" alternating, at most max per connector
  local max="$1" a="" b="" i=0 na=0 nb=0; shift
  for ip in "$@"; do
    if (( i % 2 == 0 )); then (( na < max )) && { a+="$ip "; na=$((na+1)); }
    else (( nb < max )) && { b+="$ip "; nb=$((nb+1)); }; fi; i=$((i+1))
  done; echo "${a% }|${b% }"
}
if (( ${#R1[@]} >= 2 )); then s="$(split 6 "${R1[@]}")"; R1_C1="${s%|*}"; R1_C2="${s#*|}"; src1=probed; else src1="fallback"; fi
if (( ${#R2[@]} >= 2 )); then s="$(split 6 "${R2[@]}")"; R2_C1="${s%|*}"; R2_C2="${s#*|}"; src2=probed; else src2="fallback"; fi
echo "connector 1: region1=[$R1_C1] region2=[$R2_C1]"
echo "connector 2: region1=[$R1_C2] region2=[$R2_C2]"
echo "source: region1=$src1 region2=$src2"
if [[ "${1:-}" == --write ]]; then
  { echo "# Written by probe-edges.sh on $(date '+%F %T %Z') (region1=$src1, region2=$src2)"
    echo "R1_C1=\"$R1_C1\""; echo "R2_C1=\"$R2_C1\""; echo "R1_C2=\"$R1_C2\""; echo "R2_C2=\"$R2_C2\""; } > "$DIR/edge-ips.env"
  echo "Wrote $DIR/edge-ips.env (restart connectors one at a time to apply)."
fi
