#!/usr/bin/env bash
# Reports which upstream provider auth files exist (names/counts only, never contents).
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
AUTH=$CPA_DIR/auths; shopt -s nullglob
files=("$AUTH"/*.json); total=${#files[@]}
declare -A cnt
for f in "${files[@]}"; do t=$(jq -r '.type // .provider // empty' "$f" 2>/dev/null); [ -z "$t" ] && t=$(basename "$f" | cut -d- -f1); cnt[$t]=$(( ${cnt[$t]:-0} + 1 )); done
echo "auth dir: $AUTH ($total auth files)"
for k in "${!cnt[@]}"; do echo "  $k: ${cnt[$k]}"; done
if [ "$total" -eq 0 ]; then echo "upstream: NOTICE no upstream accounts logged in yet (proxy works, but no models will route until one is added)"
else echo "upstream: OK"; fi
