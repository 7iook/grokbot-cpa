#!/usr/bin/env bash
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$R/env.sh"
flock -n "$R/.watchdog.lock" true 2>/dev/null && echo "watchdog: NOT running" || echo "watchdog: running (pid $(cat $R/watchdog.pid 2>/dev/null))"
[ -f "$R/.watchdog-stopped" ] && echo "opt-out: .watchdog-stopped present"
echo "x-ui pid: $(cat $R/x-ui.pid 2>/dev/null)  version: $($XUI_BIN -v 2>/dev/null)"
pgrep -af "^$XUI_BIN_FOLDER/xray-linux" | cut -c1-80
for p in $XUI_PANEL_PORT $XUI_SUB_PORT $XUI_NODE_PORT; do echo "port $p: $(curl -s -m 3 -o /dev/null -w %{http_code} http://127.0.0.1:$p/)"; done
ls -1t $R/backups/x-ui.db.* 2>/dev/null | head -3
"$R/tunnel.sh" status
