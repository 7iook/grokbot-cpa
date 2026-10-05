---
name: cpa-ops
description: Operate and troubleshoot an existing grokbot-cpa install (status, restart, logs, 530s, upgrades, Anthropic 403). Never print secrets.
---

# CPA operations

You are operating an existing **grokbot-cpa** install on this box. Default install dir is `~/cli-proxy-api` (look for a `.grokbot-cpa` marker and a `cpa.env`). Read `cpa.env` for `PORT`, `TUNNEL_MODE`, `PUBLIC_URL`, `AUTH_DIR`, `METRICS_BASE`.

## Hard rules

1. Never print `.tunnel-token`, `API_KEY.txt`, `MANAGEMENT_SECRET.txt`, or files under `AUTH_DIR`.
2. Prefer the scripts in the install dir over ad-hoc `kill` / `curl` loops.
3. When restarting connectors in **named** mode, restart **one at a time** (the watchdog already enforces a 60s gap). Do not stop both connectors together.
4. Do not edit the live install of another project. Confirm the `.grokbot-cpa` marker first.

## Everyday commands

```bash
D="${INSTALL_DIR:-$HOME/cli-proxy-api}"
"$D/status.sh"          # read-only overview
"$D/healthcheck.sh"     # check + repair; also start-after-reboot
"$D/start-all.sh"       # start everything that is down
"$D/stop-all.sh"        # stop watchdog first, then the rest
```

Logs (tail these, do not paste secrets if any appear):

- `$D/logs/cli-proxy-api.log`
- `$D/logs/tunnel1.log` / `tunnel2.log`
- `$D/logs/watchdog.log`
- `$D/logs/healthcheck.log`
- `$D/logs/keepalive.log`

## Restart patterns

- **API only:** `"$D/stop.sh" && "$D/start.sh"`
- **One connector:** `"$D/stop-tunnel.sh" 1 && sleep 2 && "$D/start-tunnel.sh" 1` (then the other, after ≥60s, if needed)
- **Watchdog:** `"$D/stop-watchdog.sh" && "$D/start-watchdog.sh"`
- **Full recycle:** `"$D/stop-all.sh" && "$D/start-all.sh"` then `"$D/healthcheck.sh"`

In **quick** mode a connector restart issues a **new** `*.trycloudflare.com` URL. Update `PUBLIC_URL.txt` clients afterwards; `healthcheck.sh` prints `NOTE: public URL changed ...` when it detects that.

## The 530 pattern

Cloudflare **HTTP 530** on the public URL means the edge could not reach any healthy origin connection.

What the watchdog does (every ~15s):

1. Checks each connector's `/ready` and `cloudflared_tunnel_ha_connections` on `127.0.0.1:$((METRICS_BASE+N))`.
2. Restarts a connector that is unhealthy for ~30s, with cooldowns (60s between any two connector restarts, 120s before the same one restarts again). Never restarts both at once.
3. Every ~60s, hits the public URL. One 530 (or two other failures in a row) restarts the least-healthy connector as a fallback.

What you should do when the user reports 530s:

1. `"$D/status.sh"` and read `logs/watchdog.log` / `logs/tunnelN.log`.
2. Confirm local `$PORT` still returns 200.
3. If **named** and both connectors are flapping on a Grok Bot box, the outbound proxy is likely cutting long-lived connections — dual connectors reduce but do not eliminate this. Suggest moving to a real VPS for stability.
4. Re-run `"$D/probe-edges.sh" --write` only when `HOSTS_WORKAROUND=1`, then restart connectors one at a time to pick up new edge IPs.

## Upgrades

```bash
git -C /tmp/grokbot-cpa-src pull --ff-only   # or re-clone
cd /tmp/grokbot-cpa-src
# keep existing keys/config:
INSTALL_DIR="$D" ./install.sh --no-probe
"$D/stop-all.sh" && "$D/start-all.sh"
"$D/healthcheck.sh"
```

`install.sh` is idempotent: it re-copies scripts, keeps `config.yaml` / `API_KEY.txt` unless you pass `--reset-config`, and re-downloads binaries only when the pinned version changes. Pin overrides: `CPA_VERSION`, `CLOUDFLARED_VERSION`.

## Anthropic 403 — "OAuth not allowed for this organization"

This comes from **Anthropic**, not from CPA or the tunnel. Local restarts will not fix it. Typical meaning: the Claude account / org is not allowed to use that OAuth client outside Claude Code, or the subscription was restricted.

What to tell the user:

1. Confirm in `logs/cli-proxy-api.log` that the 403 is from the upstream Claude call.
2. They can wait / contact Anthropic, or switch to an **Anthropic Console API key** (add it through CPA's config / management UI — keep `allow-remote: false`).
3. Remind them of the ToS risk of subscription OAuth outside Claude Code.

## Uninstall

```bash
"$D/uninstall.sh"          # dry run
"$D/uninstall.sh" --yes    # stop processes, delete install dir, keep AUTH_DIR
"$D/uninstall.sh" --yes --purge-auth   # also delete AUTH_DIR (Claude credentials)
```

## Changing tunnel mode

Edit `$D/cpa.env` (`TUNNEL_MODE`, `PUBLIC_URL`), then for named run `set-tunnel-token.sh`, then `"$D/stop-tunnel.sh" all && "$D/start-tunnel.sh" all`. Or re-run `install.sh` with the new env vars (it preserves keys).
