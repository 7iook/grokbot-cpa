#!/usr/bin/env bash
# Stop everything started from a grokbot-cpa install dir and delete that dir.
# Usage: uninstall.sh [--yes] [--purge-auth]
#   without --yes it only prints what would be removed.
#   --purge-auth also deletes AUTH_DIR (your Claude OAuth credentials). Kept by default.
# INSTALL_DIR: the directory this script lives in (if it is an install dir), else $INSTALL_DIR,
# else ~/cli-proxy-api. Refuses to touch a directory without the .grokbot-cpa marker.
set -uo pipefail
YES=0; PURGE=0
for a in "$@"; do case "$a" in --yes|-y) YES=1 ;; --purge-auth) PURGE=1 ;; -h|--help) sed -n '2,8p' "$0"; exit 0 ;; *) echo "unknown argument: $a" >&2; exit 2 ;; esac; done
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SELF/.grokbot-cpa" ]]; then D="$SELF"; else D="${INSTALL_DIR:-$HOME/cli-proxy-api}"; D="${D/#\~/$HOME}"; D="${D%/}"; fi
[[ -f "$D/.grokbot-cpa" ]] || { echo "ERROR: $D is not a grokbot-cpa install dir (no .grokbot-cpa marker); refusing." >&2; exit 1; }
case "$D" in /|"$HOME"|/usr*|/etc*|/bin|/sbin|/var|/tmp|"") echo "ERROR: refusing to remove $D" >&2; exit 1 ;; esac
AUTH_DIR="$(bash -c '. "$1/cpa.env" >/dev/null 2>&1; printf %s "${AUTH_DIR:-}"' _ "$D")"
echo "Will stop all processes recorded in $D/*.pid and delete $D"
if (( PURGE )); then echo "Will ALSO delete AUTH_DIR ${AUTH_DIR:-<unset>} (Claude credentials)"; else echo "Keeping AUTH_DIR ${AUTH_DIR:-<unset>} (use --purge-auth to delete it)"; fi
(( YES )) || { echo "Dry run. Re-run with --yes to do it."; exit 0; }
[[ -x "$D/stop-all.sh" ]] && "$D/stop-all.sh"
left="$(pgrep -af -- "$D/" | grep -v -- "$$" | grep -vE 'uninstall\.sh' || true)"
[[ -n "$left" ]] && { echo "WARNING: processes still referencing $D:"; echo "$left" | cut -c1-160; }
rm -rf -- "$D" && echo "Removed $D"
if (( PURGE )) && [[ -n "$AUTH_DIR" ]]; then
  case "$AUTH_DIR" in /|"$HOME"|/usr*|/etc*|/bin|/sbin|/var|/tmp) echo "ERROR: refusing to remove AUTH_DIR=$AUTH_DIR" >&2; exit 1 ;; esac
  rm -rf -- "$AUTH_DIR" && echo "Removed $AUTH_DIR"
fi
