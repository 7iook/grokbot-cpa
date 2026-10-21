#!/usr/bin/env bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# monitor.sh — independent health/pause timeline, 30s cadence.
# CSV columns: ts,iso,http_mgmt,http_models,cpa_up,tunnel_est,pause_gap_s,mem_avail_mb,load1,browse_running
# pause_gap_s: wall-clock delta minus monotonic delta between ticks (>~5 => box was paused/frozen).
set -uo pipefail
DIR="${ACTIVITY_DIR:-$HOME/box-activity-test}"
CSV="$DIR/logs/monitor.csv"
LOCKDIR="$DIR/.monitor.lock"
STOP="$DIR/.stop"
INTERVAL=30
LOG_MAX=$((10*1024*1024))
mkdir -p "$DIR/logs"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -f "$LOCKDIR/pid" ]; then
    op=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$op" ] && [ -f "/proc/$op/cmdline" ] \
       && tr '\0' ' ' < "/proc/$op/cmdline" 2>/dev/null | grep -q "[m]onitor.sh"; then
      echo "already running: pid $op"; exit 0
    fi
  fi
  rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

[ -s "$CSV" ] || echo "ts,iso,http_mgmt,http_models,cpa_up,tunnel_est,pause_gap_s,mem_avail_mb,load1,browse_running" > "$CSV"

mono() { awk '{print int($1)}' /proc/uptime; }
prev_wall=$(date +%s); prev_mono=$(mono)

while true; do
  [ -f "$STOP" ] && break
  now_wall=$(date +%s); now_mono=$(mono)
  # pause gap = how much wall advanced beyond monotonic (frozen time)
  d_wall=$((now_wall-prev_wall)); d_mono=$((now_mono-prev_mono))
  gap=$((d_wall-d_mono)); [ "$gap" -lt 0 ] && gap=0
  prev_wall=$now_wall; prev_mono=$now_mono

  http_m=$(curl -s -o /dev/null -w '%{http_code}' -m 10 https://${CF_HOSTNAME}/management.html 2>/dev/null); http_m=${http_m:-000}
  http_v=$(curl -s -o /dev/null -w '%{http_code}' -m 10 https://${CF_HOSTNAME}/v1/models 2>/dev/null); http_v=${http_v:-000}
  cpa_up=0; pgrep -f '[c]li-proxy-api' >/dev/null 2>&1 && cpa_up=1
  tun_est=$(ss -tanp 2>/dev/null | grep -c 'ESTAB.*:7844')
  mem=$(free -m | awk '/^Mem:/{print $7}')
  load1=$(awk '{print $1}' /proc/loadavg)
  br=0; [ -f "$DIR/.browse.lock/pid" ] && { bp=$(cat "$DIR/.browse.lock/pid" 2>/dev/null); [ -n "$bp" ] && [ -d "/proc/$bp" ] && br=1; }

  echo "$now_wall,$(date -d @$now_wall '+%FT%T'),$http_m,$http_v,$cpa_up,$tun_est,$gap,$mem,$load1,$br" >> "$CSV"
  sz=$(stat -c %s "$CSV" 2>/dev/null || echo 0); [ "$sz" -gt "$LOG_MAX" ] && { head -1 "$CSV" > "$CSV.h"; tail -c "$LOG_MAX" "$CSV" | sed '1d' >> "$CSV.h"; mv -f "$CSV.h" "$CSV"; }

  for ((s=0;s<INTERVAL;s++)); do sleep 1; [ -f "$STOP" ] && break; done
done
