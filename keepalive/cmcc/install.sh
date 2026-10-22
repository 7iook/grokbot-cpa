#!/usr/bin/env bash
# Install the cmcc-cloud-alive WebUI (third-party, MIT: github.com/1936-zero/cmcc-cloud-alive) plus our supervisor.
# Accounts/passwords are entered in the WebUI (127.0.0.1:${CMCC_WEBUI_PORT:-28080}) and never stored in this repo.
set -euo pipefail
REPO=${CMCC_REPO:-https://github.com/1936-zero/cmcc-cloud-alive.git}
REF=${CMCC_REF:-210c9d5}               # commit running on the reference box (2026-10)
APP=${CMCC_DIR:-$HOME/cmcc-cloud-alive}
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV" && APP=${CMCC_DIR:-$APP}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "$APP/.git" ] || timeout 300 git clone -q "$REPO" "$APP"
timeout 120 git -C "$APP" fetch -q origin && git -C "$APP" checkout -q "$REF"
[ -x "$APP/.venv-webui/bin/python" ] || python3 -m venv "$APP/.venv-webui"
timeout 600 "$APP/.venv-webui/bin/pip" install -q -e "${APP}[web]"
install -m 755 "$HERE/supervise.sh" "$APP/supervise.sh"
echo "cmcc-cloud-alive ready at $APP (start: bash $APP/supervise.sh)"
