---
name: cpa-ops
description: Operate and troubleshoot a grokbot-cpa box-scheme install (CPA + named tunnel + Tailscale watchdogs, boot autostart, keepalives): status, start/stop, logs, tunnel restart, upgrades, Anthropic 403. Never print secrets.
---

# CPA operations (box scheme)

Settings: `~/.config/grokbot-cpa/box.env` (`CPA_DIR` default `~/cli-proxy-api`, `TS_DIR` default `/workspace/tailscale`,
`CF_HOSTNAME`, `CF_TUNNEL`, `CPA_PORT` 8317, `CPA_SOURCE_REPO`/`CPA_SOURCE_REF`, `LOG_TZ`).

## Hard rules
1. Never print: `$CPA_DIR/secrets/*` (client-api-key, management-secret, …), `$CPA_DIR/auths/*`, `$CPA_DIR/config.yaml`
   key lines, `$CPA_DIR/cloudflared/*.json`, `$TS_DIR/authkey`, `$TS_DIR/tailscaled.state`.
2. Use the scripts; do not `kill` processes ad hoc (the watchdogs would fight you).
3. Daemons are started with a clean environment (`env -i`) on purpose so agent-session secrets never leak into them.

## How it runs
- Boot: XFCE autostart `~/.config/autostart/boot-services.desktop` → `~/boot-services.sh` → starts the CPA watchdog and
  `$TS_DIR/ensure-up.sh` (which starts the Tailscale watchdog). Missing deps/binaries → `/workspace/cpa-bootstrap.sh`.
- `$CPA_DIR/watchdog.sh`: single instance (flock), runs CPA as its child, health checks, hang kill, backoff, detects VM
  pause/snapshot-resume and stale tunnel flows → refreshes the tunnel, rotates logs, relaunches the Tailscale watchdog.
- `$TS_DIR/watchdog.sh`: restarts tailscaled when offline (≈20s), restores state backup, re-applies `tailscale serve`
  of `CPA_PORT`, relaunches `boot-services.sh` if the CPA watchdog is gone.
- Keepalives (optional): `~/cmcc-cloud-alive/supervise.sh` (WebUI 127.0.0.1:28080, own autostart entry) and
  `~/box-activity-test/ctl.sh start-all|stop|status` (browse loop + 30s monitor CSV).

## Commands
```bash
D=~/cli-proxy-api; T=/workspace/tailscale
$D/status.sh                     # overview (read-only)
$D/healthcheck.sh                # check + self-heal; RESULT: OK|FIXED|FAILED
$D/start-watchdog.sh             # start watchdog (starts CPA + tunnel), clears .watchdog-stopped
$D/stop-all.sh                   # stop watchdog (sets .watchdog-stopped), tunnel, CPA
$D/stop.sh && $D/start.sh        # restart CPA only (watchdog adopts it)
$D/restart-tunnel.sh [fast]      # serialized tunnel restart
touch $D/.maintenance            # pause CPA restarts while watchdog keeps running (rm to resume)
$D/upstream-check.sh             # auth files per provider (counts only)
$D/refresh-model-catalog.sh      # save /v1/models to $D/models/models.json
$D/claude-login.sh start|status|paste URL|stop
$D/install-plugins.sh [--force]  # (re)install plugins from box.env CPA_PLUGINS + 缓存保活 (no Lamplighter)
bash $T/ensure-up.sh             # bring Tailscale up (TS_AUTHKEY=... $T/set-authkey.sh if state was lost)
touch $T/.watchdog-stopped       # keep the Tailscale watchdog from being relaunched
```
Logs: `$D/logs/{watchdog.log,cpa.out,tunnel.log,boot.log}`, `$T/{ensure-up.log,watchdog.log,tailscaled.log}`,
`~/cmcc-cloud-alive/logs/`, `~/box-activity-test/logs/`.

## Public 530 / 502
Cloudflare could not reach a live connector. Usually the box was paused/restored and the tunnel's edge flows died:
the watchdog detects this (`vm_resumed`, `tunnel_conns_stale`) and refreshes; manually: `$D/restart-tunnel.sh fast`.
DNS on the box returns fake 198.18.x.x addresses, so `start-tunnel.sh` resolves real edge IPs via OpenDNS:5353
(`cloudflared/resolve-edge.py`). Check `$D/logs/tunnel.log`.

## Upgrades
```bash
git -C ~/grokbot-cpa pull --ff-only && cd ~/grokbot-cpa
rm -f ~/cli-proxy-api/bin/cli-proxy-api            # force a rebuild of CPA_SOURCE_REF (or set CPA_SOURCE_REF=<commit>)
./install.sh                                       # keeps config.yaml, secrets, auths, tailscale state
~/cli-proxy-api/stop.sh                            # watchdog restarts CPA with the new binary
```
Release binary instead of the fork: `CPA_BUILD=release` in box.env.

## Anthropic 403 "OAuth not allowed for this organization"
Comes from Anthropic, not CPA/tunnel; restarts do not help. Confirm in `$D/logs/cpa.out`; options: wait/contact
Anthropic, or use an Anthropic Console API key (`claude-api-key` in config.yaml). Remind the user of the ToS risk.

## Uninstall
`~/grokbot-cpa/uninstall.sh` (dry run) · `--yes` (stop + remove autostart) · `--yes --purge` (also deletes CPA_DIR/TS_DIR incl. secrets).
