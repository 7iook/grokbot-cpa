#!/usr/bin/env bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# browse-loop.sh — box-internal activity generator.
# Every ~60s: open 2-3 random pages in a real headful Chrome on Xvfb :2,
# keep them a few seconds, then close. Logs each cycle. Single-instance.
# Graceful stop: touch $DIR/.stop  (loop exits within one cycle).
set -uo pipefail

DIR="${ACTIVITY_DIR:-$HOME/box-activity-test}"
LOG="$DIR/logs/browse.ndjson"
LOCKDIR="$DIR/.browse.lock"
STOP="$DIR/.stop"
DISPLAY_NUM=":2"
PROFILE="$DIR/chrome-profile"
LOG_MAX=$((10*1024*1024))

mkdir -p "$DIR/logs" "$PROFILE"

# --- single instance (atomic mkdir; dir not inherited by children) ---
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -f "$LOCKDIR/pid" ]; then
    op=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$op" ] && [ -f "/proc/$op/cmdline" ] \
       && tr '\0' ' ' < "/proc/$op/cmdline" 2>/dev/null | grep -q "[b]rowse-loop.sh"; then
      echo "already running: pid $op"; exit 0
    fi
  fi
  rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

log() { printf '%s\n' "$1" >> "$LOG"; }
trim() { local sz; sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0); [ "$sz" -gt "$LOG_MAX" ] && { tail -c "$LOG_MAX" "$LOG" | sed '1d' > "$LOG.t" && mv -f "$LOG.t" "$LOG"; }; }

URLS=(
  "https://en.wikipedia.org/wiki/Special:Random"
  "https://news.ycombinator.com/"
  "https://www.bing.com/search?q=cloud+sandbox"
  "https://github.com/trending"
  "https://www.reddit.com/r/programming/"
  "https://stackoverflow.com/questions"
  "https://www.google.com/search?q=keepalive"
  "https://example.com/"
  "https://httpbin.org/delay/1"
  "https://www.wikipedia.org/"
)

CHROME=/usr/bin/google-chrome
COMMON_FLAGS=(--no-first-run --no-default-browser-check --disable-gpu
  --disable-dev-shm-usage --disable-background-networking
  --disable-features=Translate,BackForwardCache
  --user-data-dir="$PROFILE" --window-size=1600,1000 --window-position=40,40)

cycle=0
log "{\"ev\":\"start\",\"ts\":$(date +%s),\"pid\":$$,\"display\":\"$DISPLAY_NUM\"}"

while true; do
  [ -f "$STOP" ] && { log "{\"ev\":\"stop\",\"ts\":$(date +%s),\"cycle\":$cycle}"; break; }
  cycle=$((cycle+1))
  # pick 2-3 random urls
  n=$(( (RANDOM % 2) + 2 ))
  picks=()
  for ((k=0;k<n;k++)); do picks+=("${URLS[$((RANDOM % ${#URLS[@]}))]}"); done
  t0=$(date +%s)
  # launch chrome headful on Xvfb :2, open all picks as tabs; run bounded time
  DISPLAY="$DISPLAY_NUM" timeout 40 "$CHROME" "${COMMON_FLAGS[@]}" "${picks[@]}" \
      >/dev/null 2>>"$DIR/logs/chrome.err" &
  cpid=$!
  # let pages load/render ~ 12-20s, nudge the mouse for desktop activity
  dwell=$(( (RANDOM % 9) + 12 ))
  for ((s=0;s<dwell;s++)); do
    DISPLAY="$DISPLAY_NUM" xdotool mousemove $((RANDOM%1500+50)) $((RANDOM%900+50)) 2>/dev/null
    sleep 1
    [ -f "$STOP" ] && break
  done
  # close this chrome instance
  kill "$cpid" 2>/dev/null; sleep 1; kill -9 "$cpid" 2>/dev/null
  # also sweep any lingering chrome on this profile
  pkill -9 -f "user-data-dir=$PROFILE" 2>/dev/null
  t1=$(date +%s)
  mem=$(free -m | awk '/^Mem:/{print $7}')
  log "{\"ev\":\"cycle\",\"ts\":$t1,\"cycle\":$cycle,\"n\":$n,\"dwell\":$dwell,\"dur\":$((t1-t0)),\"mem_avail_mb\":$mem}"
  trim
  # sleep remainder up to ~60s cadence
  spent=$((t1-t0)); rest=$((60-spent)); [ "$rest" -lt 5 ] && rest=5
  for ((s=0;s<rest;s++)); do sleep 1; [ -f "$STOP" ] && break; done
done
