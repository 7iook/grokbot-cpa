---
name: grokbot-setup
description: PRIMARY ENTRY POINT. Set up a complete grokbot-cpa box end to end - CPA (custom build) + 4 plugins, Cloudflare named tunnel, Tailscale with SSH, CPA/Tailscale watchdogs, boot autostart, cmcc + box-activity keepalives, AdsPower + RoxyBrowser - asking the user once for all inputs, then doing everything and self-checking.
---

# grokbot-setup (do everything, ask once)

Repo: `https://github.com/7iook/grokbot-cpa`. Everything is ON by default; only skip a component if the user says so
(`--no-tunnel --no-tailscale --no-plugins --no-browsers --no-cmcc --no-activity`).

## Rules
1. **Ask once.** Collect every external input in ONE message/form (below), then work without further questions
   except the Cloudflare/Claude browser authorizations that only the user can click.
2. **Secrets only via masked secret input** (env vars). Never echo, log or paste them back. If the user pastes a secret
   in chat, ask them to rotate it.
3. **Persistence:** on a Grok Bot box only `/home/box` (PERSIST_ROOT) survives a reboot; `/workspace`, `/usr`, `/etc`,
   `/opt` and apt packages can vanish. All binaries, configs, secrets, cert.pem, tailscale state, plugins and browsers are
   under PERSIST_ROOT; apt packages are re-ensured by `boot-services.sh` at every start. Never move them elsewhere.
4. Wrap anything that can hang in `timeout`. Do not overwrite an existing `config.yaml`, `secrets/`, `auths/`, tailscale state.

## 1. The single questionnaire
| # | Ask | Goes to |
|---|---|---|
| 1 | Hostname for CPA, e.g. `api.example.com` (its zone must be in their Cloudflare account) | `CF_HOSTNAME` (box.env) |
| 2 | "I will show you a Cloudflare authorization link — open it, log in, pick the zone, click Authorize." (confirm they can) | `cf-setup.sh login` |
| 3 | Tailscale **reusable** auth key (Settings → Keys) — masked secret | env `TS_AUTHKEY` |
| 4 | Tailnet device name (default `cpa-box`) | `TS_HOSTNAME` |
| 5 | cmcc (爱家移动云电脑) keepalive: do they use it? Account/password are entered by them in the WebUI (http://127.0.0.1:28080 in the box browser), never in chat | – |
| 6 | AdsPower / RoxyBrowser: no account needed to install; they log in inside the app themselves if they want | – |
| 7 | Anything to skip? (default: nothing) | `--no-*` flags |
| 8 | Claude login now? (risk notice: subscription OAuth outside Claude Code may violate Anthropic ToS / 403) | `claude-login.sh` |

## 2. Run (in this order)
```bash
timeout 120 git clone https://github.com/7iook/grokbot-cpa.git ~/grokbot-cpa || timeout 60 git -C ~/grokbot-cpa pull --ff-only
cd ~/grokbot-cpa
CF_HOSTNAME=<1> TS_HOSTNAME=<4> TS_AUTHKEY="$TS_AUTHKEY" ./install.sh        # + --no-* only if asked
```
`install.sh` does, in order: persistent layout + apt deps → CPA built from `7iook/CLIProxyAPI@feat/claude-setup-token-quota`
→ boot hooks in `~/.profile`+`~/.bashrc` (+ .desktop for compat) → keepalives (cmcc, box-activity) → AdsPower + RoxyBrowser → config.yaml + secrets → CPA watchdog
→ plugins (缓存保活, Claude Keep Rolling, API Key Billing, 用量统计; never Lamplighter) → Cloudflare (`cf-setup.sh login`
prints the authorize URL if not authorized) → Tailscale up **with SSH** → boot-services (keepalive supervisors) → selfcheck.

Then:
1. Show the user the Cloudflare URL printed by install.sh (or `~/cli-proxy-api/cf-setup.sh login`). After they authorize:
   `timeout 400 ~/cli-proxy-api/cf-setup.sh setup` (reuses or creates tunnel `CF_TUNNEL`, routes DNS, writes config, starts it).
   Alternative if they already have credentials JSON: `CF_TUNNEL_CREDENTIALS_FILE=<id>.json ~/cli-proxy-api/set-tunnel-creds.sh`.
2. Claude: `~/cli-proxy-api/claude-login.sh start` → open the URL in **this box's browser** → `claude-login.sh status` = LOGGED_IN.
3. If a plugin failed: `~/cli-proxy-api/install-plugins.sh` then `~/cli-proxy-api/stop.sh` (watchdog restarts CPA).
4. `~/grokbot-cpa-bin/selfcheck.sh` (same `--no-*` flags) until `SELFCHECK: PASS`; fix each FAIL line and re-run.
5. Optional (offer it): a Grok Bot routine `@every 10m` whose prompt is "run `bash ~/boot-services.sh` in Shell; reply only on error".
   Not required: Boot trigger on a Grok Bot box: there is no systemd/cron and the desktop is only a window manager, so XDG autostart (`~/.config/autostart/*.desktop`, kept for compat) does **not** fire. The chain is: bot wakes → first agent Shell → exec-daemon initializes it with `bash -ilc` → `~/.profile`/`~/.bashrc` → marked `grokbot-cpa boot hook` block (written by `box/install-hooks.sh`) → `~/boot-services.sh` (waits for the home restore `/tmp/sand-copy-in-status.json`, then starts only supervisors whose lock is free).
   A reboot only happens when the bot is woken, and its first Shell fires the hook; the routine covers wakes without a Shell call.
6. After a VM swap the SSH host key changes and the tailnet name may get a `-1` suffix (old device offline): tell the user to
   remove the offline duplicate in the Tailscale admin and clients to `ssh-keygen -R <ip>`.

## 3. Report to the user
Public base URL `https://<CF_HOSTNAME>`, tailnet `http://<TS_HOSTNAME>:8317`, where the client key is
(`~/cli-proxy-api/secrets/client-api-key`, show once only if asked), selfcheck summary, and what needs them
(cmcc WebUI login, AdsPower/Roxy login, Claude accounts). Day-2 operations: skill `cpa-ops`.

## Layout (PERSIST_ROOT=/home/box)
`cli-proxy-api/` (bin/cli-proxy-api, bin/cloudflared, config.yaml, secrets/{client-api-key,management-secret,cf-cert.pem},
auths/, plugins/, cloudflared/{config.yml,<id>.json}, logs/) · `tailscale/` (binaries, tailscaled.state, authkey) ·
`boot-services.sh`, `cpa-bootstrap.sh` · `.local/go` · `build/cpa` · `adspower/`, `roxybrowser/` (+ `~/.config/adspower_global`,
`~/.config/RoxyBrowser` profiles) · `cmcc-cloud-alive/` · `box-activity-test/` · `grokbot-cpa-bin/selfcheck.sh` ·
`.config/grokbot-cpa/box.env` · boot hook blocks in `.profile` + `.bashrc` · `.config/autostart/{boot-services,cmcc-keepalive}.desktop` (compat only).
