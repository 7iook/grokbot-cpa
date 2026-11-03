# shellcheck shell=bash
# 3x-ui environment (sourced by watchdog/start/stop/status/tunnel/cf-setup/install). No secrets here:
# panel login + node ids live in $XUI_ROOT/secrets/{panel,node}.env (600), tunnel creds in $XUI_ROOT/cloudflared/<id>.json.
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa site settings
XUI_ROOT=${XUI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
export XUI_MAIN_FOLDER=$XUI_ROOT/app
export XUI_BIN_FOLDER=$XUI_ROOT/app/bin
export XUI_DB_FOLDER=$XUI_ROOT/db
export XUI_LOG_FOLDER=$XUI_ROOT/logs
export XRAY_VMESS_AEAD_FORCED=false
XUI_BIN=$XUI_ROOT/app/x-ui
# all three listen on 127.0.0.1 only; public access goes through the 3x-ui Cloudflare tunnel
XUI_PANEL_PORT=${XUI_PANEL_PORT:-20530}   # panel (webBasePath /)
XUI_SUB_PORT=${XUI_SUB_PORT:-20531}       # subscription server
XUI_NODE_PORT=${XUI_NODE_PORT:-20532}     # VLESS-WS inbound
# Cloudflare tunnel (locally managed: ingress in cloudflared/config.yml, written by cf-setup.sh)
XUI_CF_TUNNEL=${XUI_CF_TUNNEL:-grokbot-3xui}
XUI_CF_BIN=$XUI_ROOT/bin/cloudflared
XUI_CF_CONFIG=$XUI_ROOT/cloudflared/config.yml
XUI_CF_PIDFILE=$XUI_ROOT/tunnel.pid
XUI_CF_METRICS=${XUI_CF_METRICS:-127.0.0.1:20242}
XUI_CF_HOSTNAME=${XUI_CF_HOSTNAME:-}       # panel host, e.g. 3x.example.com (empty = no public probe)
XUI_SUB_HOSTNAME=${XUI_SUB_HOSTNAME:-}     # subscription host, e.g. sub3x.example.com
XUI_NODE_HOSTNAME=${XUI_NODE_HOSTNAME:-}   # node (VLESS-WS over CF, TLS 443) host, e.g. node3x.example.com
LOG_TZ=${LOG_TZ:-Asia/Shanghai}
