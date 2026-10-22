#!/usr/bin/env bash
# Write the grokbot-cpa boot hook into ~/.profile and ~/.bashrc (idempotent, marked block at the top of each file).
# Why: on a Grok Bot box XDG autostart never fires; the agent's Shell is initialized with `bash -ilc`, which reads
# ~/.profile/~/.bashrc, so the first Shell after the bot wakes launches boot-services.sh (lock-protected, detached).
# Unmarked older hook lines that call boot-services.sh are removed (backup: <file>.bak-hook-<ts>).
#   install-hooks.sh [--check]   --check: exit 1 if a block is missing (no changes)
set -euo pipefail
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"
BS=${BOOT_SERVICES:-$HOME/boot-services.sh}
B='# >>> grokbot-cpa boot hook >>>'; E='# <<< grokbot-cpa boot hook <<<'
BLOCK="$B
# bot wakes -> first agent Shell (bash -ilc) -> this line -> boot-services.sh (single instance via flock, detached)
[ -x \"$BS\" ] && command -v setsid >/dev/null 2>&1 && setsid -f /bin/bash \"$BS\" </dev/null >/dev/null 2>&1
$E"
rc=0
for f in "$HOME/.profile" "$HOME/.bashrc"; do
  if [ "${1:-}" = --check ]; then grep -qF "$B" "$f" 2>/dev/null || { echo "missing hook in $f"; rc=1; }; continue; fi
  touch "$f"
  cur=$(awk -v b="$B" -v e="$E" '$0==b{f=1} f{print} $0==e{f=0}' "$f")
  old=$(awk -v b="$B" -v e="$E" '$0==b{f=1;next} $0==e{f=0;next} !f && /boot-services\.sh/' "$f")
  [ "$cur" = "$BLOCK" ] && [ -z "$old" ] && { echo "hook ok: $f"; continue; }
  cp -p "$f" "$f.bak-hook-$(date +%Y%m%d-%H%M%S)"
  { printf '%s\n' "$BLOCK"
    awk -v b="$B" -v e="$E" '$0==b{f=1;next} $0==e{f=0;next} f{next} /boot-services\.sh/{next} /^# grokbot-cpa: \(re\)start box services/{next} {print}' "$f"
  } > "$f.tmp.$$" && cat "$f.tmp.$$" > "$f" && rm -f "$f.tmp.$$"
  echo "hook written: $f${old:+ (replaced old unmarked hook line)}"
done
exit $rc
