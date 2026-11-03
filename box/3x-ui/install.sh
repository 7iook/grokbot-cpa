#!/usr/bin/env bash
# Install / update 3X-UI (github.com/MHSanaei/3x-ui) under $XUI_DIR (default ~/3x-ui, box-owned so it survives a
# VM swap). Panel, subscription server and one VLESS-WS inbound listen on 127.0.0.1 only (XUI_PANEL_PORT/SUB_PORT/
# NODE_PORT, default 20530/20531/20532); public access goes through its own Cloudflare tunnel (cf-setup.sh).
# Idempotent: keeps db/, secrets/, cloudflared/; re-running applies ports/listen/sub settings from box.env.
#   box/3x-ui/install.sh [--no-start]
# Settings (box.env): XUI_DIR XUI_VERSION XUI_PANEL_PORT XUI_SUB_PORT XUI_NODE_PORT XUI_CF_TUNNEL XUI_CF_HOSTNAME
#   XUI_SUB_HOSTNAME XUI_NODE_HOSTNAME XUI_SUB_TITLE; optional one-shot env XUI_ADMIN_USER / XUI_ADMIN_PASS (else random).
# Secrets written (600, never printed): $XUI_DIR/secrets/panel.env (XUI_USER XUI_PASS XUI_PATH XUI_SUBPATH),
#   $XUI_DIR/secrets/node.env (WS_PATH CLIENT_ID SUB_ID).
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); REPO=$(cd "$SRC/../.." && pwd)
START=1; for a in "$@"; do case "$a" in --no-start) START=0;; -h|--help) sed -n '2,10p' "$0"; exit 0;; *) echo "unknown option $a" >&2; exit 2;; esac; done
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"
D=${XUI_DIR:-${PERSIST_ROOT:-$HOME}/3x-ui}; V=${XUI_VERSION:-v3.11.0}
for c in curl tar python3 openssl flock; do command -v "$c" >/dev/null || { echo "missing $c" >&2; exit 1; }; done
mkdir -p "$D"/{app,bin,db,secrets,cloudflared,backups,logs}; chmod 700 "$D/secrets" "$D/db" "$D/cloudflared"
install -m 644 "$SRC/env.sh" "$D/env.sh"
for f in watchdog.sh start.sh stop.sh status.sh tunnel.sh cf-setup.sh; do install -m 755 "$SRC/$f" "$D/$f"; done
install -m 700 "$SRC/api.py" "$D/api.py"
install -m 644 "$REPO/box/cpa/resolve-edge.py" "$D/cloudflared/resolve-edge.py"
install -m 644 "$REPO/templates/3x-ui-cloudflared.yml.tmpl" "$D/cloudflared/config.yml.tmpl"
export XUI_ROOT=$D; . "$D/env.sh"
running() { ! flock -n "$D/.watchdog.lock" true 2>/dev/null; }
WAS=0; running && WAS=1
pause() { if running; then "$D/stop.sh" >/dev/null; rm -f "$D/.watchdog-stopped"; fi; }

# 1. x-ui release (tarball kept in backups/ for offline re-installs)
cur=$("$XUI_BIN" -v 2>/dev/null || true)
if [ "$cur" != "${V#v}" ]; then
  case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "unsupported arch" >&2; exit 1;; esac
  T="$D/backups/x-ui-linux-$A-$V.tar.gz"
  if [ ! -s "$T" ]; then
    timeout 600 curl -fsSL -o "$T.part" "https://github.com/MHSanaei/3x-ui/releases/download/$V/x-ui-linux-$A.tar.gz" && mv -f "$T.part" "$T" || rm -f "$T.part"
  fi
  [ -s "$T" ] || { echo "download of 3x-ui $V failed" >&2; exit 1; }
  pause
  [ -s "$D/db/x-ui.db" ] && cp -f "$D/db/x-ui.db" "$D/backups/x-ui.db.pre-$V-$(date +%Y%m%d-%H%M%S)"
  rm -rf "$D/app.new"; mkdir -p "$D/app.new"; tar xzf "$T" -C "$D/app.new" --strip-components=1
  chmod 755 "$D/app.new/x-ui" "$D/app.new/bin/"xray-linux-* 2>/dev/null || true
  rm -rf "$D/app.old"; [ -d "$D/app" ] && mv "$D/app" "$D/app.old"; mv "$D/app.new" "$D/app"; rm -rf "$D/app.old"
  echo "3x-ui $V installed in $D/app (was: ${cur:-none})"
fi
# 2. cloudflared for its tunnel: a copy of CPA's binary when present (else cf-setup.sh downloads it)
C=${CPA_DIR:-$HOME/cli-proxy-api}/bin/cloudflared
[ -x "$XUI_CF_BIN" ] || [ ! -x "$C" ] || install -m 755 "$C" "$XUI_CF_BIN"
# 3. secrets (generated once)
umask 077
if [ ! -s "$D/secrets/panel.env" ]; then
  printf 'XUI_USER=%s\nXUI_PASS=%s\nXUI_PATH=/\n' "${XUI_ADMIN_USER:-admin-$(openssl rand -hex 3)}" "${XUI_ADMIN_PASS:-$(openssl rand -hex 16)}" > "$D/secrets/panel.env"
  NEWPASS=1; echo "generated panel login -> $D/secrets/panel.env"
fi
[ -s "$D/secrets/node.env" ] || { printf 'WS_PATH=/%s\nCLIENT_ID=%s\nSUB_ID=%s\n' "$(openssl rand -hex 8)" "$(python3 -c 'import uuid; print(uuid.uuid4())')" "$(openssl rand -hex 8)" > "$D/secrets/node.env"; echo "generated node ids -> $D/secrets/node.env"; }
umask 022
# 4. panel settings (x-ui must be stopped while its DB is edited)
pause
cd "$XUI_MAIN_FOLDER"
if [ ! -s "$D/db/x-ui.db" ] || [ "${NEWPASS:-0}" = 1 ]; then
  ( . "$D/secrets/panel.env"; "$XUI_BIN" setting -username "$XUI_USER" -password "$XUI_PASS" >/dev/null )
fi
"$XUI_BIN" setting -port "$XUI_PANEL_PORT" -webBasePath / -listenIP 127.0.0.1 >/dev/null
SUBP=$(XUI_SUB_PORT=$XUI_SUB_PORT XUI_SUB_HOSTNAME=$XUI_SUB_HOSTNAME XUI_SUB_TITLE=${XUI_SUB_TITLE:-grokbot-3x} python3 - "$D/db/x-ui.db" <<'PY'
import os, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
get = lambda k: (c.execute("select value from settings where key=?", (k,)).fetchone() or [None])[0]
def put(k, v):
    if c.execute("update settings set value=? where key=?", (v, k)).rowcount == 0:
        c.execute("insert into settings(key, value) values(?, ?)", (k, v))
put("subEnable", "true"); put("subJsonEnable", "true"); put("subClashEnable", "true")
put("subListen", "127.0.0.1"); put("subPort", os.environ["XUI_SUB_PORT"])
put("trustedProxyCIDRs", "127.0.0.1/32,::1/128")      # cloudflared connects from localhost
if not get("subTitle"): put("subTitle", os.environ["XUI_SUB_TITLE"])
h = os.environ.get("XUI_SUB_HOSTNAME", "")
for k, u in (("subPath", "subURI"), ("subJsonPath", "subJsonURI"), ("subClashPath", "subClashURI")):
    p = get(k) or ""
    if h and p: put(u, "https://" + h + p)
c.commit(); print(get("subPath") or "")
PY
)
grep -q '^XUI_SUBPATH=' "$D/secrets/panel.env" && sed -i "s#^XUI_SUBPATH=.*#XUI_SUBPATH=$SUBP#" "$D/secrets/panel.env" || echo "XUI_SUBPATH=$SUBP" >> "$D/secrets/panel.env"
cd "$D"
echo "3x-ui settings: panel 127.0.0.1:$XUI_PANEL_PORT (webBasePath /), sub 127.0.0.1:$XUI_SUB_PORT, node 127.0.0.1:$XUI_NODE_PORT"
[ $START = 1 ] || [ $WAS = 1 ] || { echo "not starting (--no-start); start: $D/start.sh"; exit 0; }
# 5. start (watchdog runs x-ui as its child) and create the default inbound on first install
"$D/start.sh" >/dev/null
for _ in $(seq 1 60); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$XUI_PANEL_PORT/")" != 000 ] && break; sleep 1; done
XUI_PANEL_PORT=$XUI_PANEL_PORT XUI_NODE_PORT=$XUI_NODE_PORT XUI_NODE_HOSTNAME=$XUI_NODE_HOSTNAME XUI_ROOT=$D python3 - <<'PY'
import json, os, sys, time
sys.path.insert(0, os.environ["XUI_ROOT"]); import api
for i in range(30):
    try: api.login(); break
    except Exception as e:
        if i == 29: print("3x-ui login failed:", str(e)[:200]); sys.exit(1)
        time.sleep(2)
lst = api.req("/panel/api/inbounds/list")
if lst.get("obj"):
    print("3x-ui inbounds present: %d (not touched)" % len(lst["obj"])); sys.exit(0)
n = dict(l.strip().split("=", 1) for l in open(os.path.join(os.environ["XUI_ROOT"], "secrets", "node.env")) if "=" in l)
port = int(os.environ["XUI_NODE_PORT"]); host = os.environ.get("XUI_NODE_HOSTNAME", "")
stream = {"network": "ws", "security": "none",
          "wsSettings": {"acceptProxyProtocol": False, "path": n["WS_PATH"], "host": host, "headers": {}, "heartbeatPeriod": 0}}
if host:  # clients connect to the CF edge: TLS on 443 at the node hostname
    stream["externalProxy"] = [{"forceTls": "tls", "dest": host, "port": 443, "remark": ""}]
inb = {"up": 0, "down": 0, "total": 0, "remark": "node-vless-ws", "enable": True, "expiryTime": 0,
       "listen": "127.0.0.1", "port": port, "protocol": "vless",
       "settings": json.dumps({"clients": [{"id": n["CLIENT_ID"], "email": "default", "limitIp": 0, "totalGB": 0,
                                             "expiryTime": 0, "enable": True, "tgId": 0, "subId": n["SUB_ID"], "comment": "",
                                             "reset": 0}], "decryption": "none", "fallbacks": []}),
       "streamSettings": json.dumps(stream),
       "sniffing": json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": False})}
r = api.req("/panel/api/inbounds/add", inb, js=True)
ok = isinstance(r, dict) and r.get("success")
print("3x-ui default inbound (VLESS-WS 127.0.0.1:%d) %s" % (port, "created" if ok else "FAILED: " + str(r if not isinstance(r, dict) else r.get("msg"))[:200]))
sys.exit(0 if ok else 1)
PY
echo "3x-ui up. Panel: http://127.0.0.1:$XUI_PANEL_PORT/ (login in $D/secrets/panel.env). Tunnel: $D/cf-setup.sh setup. Status: $D/status.sh"
