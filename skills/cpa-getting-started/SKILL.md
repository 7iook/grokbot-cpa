---
name: cpa-getting-started
description: Onboard a user onto CLIProxyAPI (CPA) on this Grok Bot box with the grokbot-cpa box scheme (CPA built from the 7iook fork, named Cloudflare tunnel, Tailscale, watchdogs, boot autostart, optional keepalives). One question at a time, secrets only through secure input.
---

# CPA getting started (box scheme)

> **For a full setup use `skills/grokbot-setup/SKILL.md` (primary entry point: one questionnaire, installs everything, self-check).**
> This skill covers the CPA part only. Cloudflare default path: `cf-setup.sh login` (show the URL) → `cf-setup.sh setup`.

Repo: `https://github.com/7iook/grokbot-cpa`. Everything is configured by `~/.config/grokbot-cpa/box.env`
(template `box/box.env.example`) and installed by `./install.sh`. Ask **one question at a time**.

## Hard rules

1. Never put a secret in chat: Tailscale auth key, Cloudflare tunnel credentials, client API key, management
   secret, Claude credentials. Request them with the bot's **secure secret input** (env vars `TS_AUTHKEY`,
   `CF_TUNNEL_CREDENTIALS`). If the user pasted one in chat, ask them to rotate it.
2. Detect what is already installed first (`~/cli-proxy-api`, `~/tailscale`, `~/.config/grokbot-cpa/box.env`,
   `~/.config/autostart/*.desktop`) and do not overwrite an existing `config.yaml`, `secrets/`, `auths/` or tailscale state.
3. Tell the user what you will run before running it. Open OAuth URLs in **this box's own browser**.
4. Say the risk notice once before Claude login.

## Risk notice

> Using a Claude subscription's OAuth outside Claude Code (including through CPA) may violate Anthropic's terms and can lead to account action or 403 errors such as "OAuth not allowed for this organization". An Anthropic Console API key is the ToS-safe path. Continue only if you accept that risk.

## Flow

### 1. Scope (one small card)
Ask what to install: CPA + tunnel (required), Tailscale (recommended: tailnet access + the second watchdog),
keepalives: `cmcc` (爱家移动云电脑 WebUI) and/or `box-activity` (keeps this box active with a browse loop).

### 2. Collect inputs (all at once, secrets via secure input)
- Public hostname for the named tunnel, e.g. `api.example.com` → `CF_HOSTNAME`.
- Cloudflare named-tunnel credentials JSON (`cloudflared tunnel create <name>` → `<tunnel-id>.json`) → secure `CF_TUNNEL_CREDENTIALS`.
  Route the hostname to the tunnel in Cloudflare (DNS CNAME `<id>.cfargotunnel.com`).
- Tailscale **reusable** auth key → secure `TS_AUTHKEY`; optional tailnet name `TS_HOSTNAME`.

### 3. Install
```bash
git clone https://github.com/7iook/grokbot-cpa.git ~/grokbot-cpa   # or: git -C ~/grokbot-cpa pull --ff-only
cd ~/grokbot-cpa
CF_HOSTNAME=api.example.com TS_HOSTNAME=cpa-box ./install.sh   # everything on; add --no-cmcc / --no-activity / --no-browsers to skip
```
- CPA is **built from source**: `CPA_SOURCE_REPO=https://github.com/7iook/CLIProxyAPI.git`,
  `CPA_SOURCE_REF=feat/claude-setup-token-quota` (Go is downloaded if missing). Release binary instead:
  `CPA_BUILD=release CPA_VERSION=v8.0.29 ./install.sh`.
- `install.sh` writes `config.yaml` with a fresh client key (copy in `~/cli-proxy-api/secrets/client-api-key`)
  and management secret (`secrets/management-secret`), installs boot autostart (`~/.config/autostart/boot-services.desktop`).

### 3b. Plugins (required; done by install.sh)
`install.sh` runs `~/cli-proxy-api/install-plugins.sh` right after CPA starts and installs exactly these four
(never install **Lamplighter**):
| Panel name | Plugin id | How |
|---|---|---|
| 缓存保活 | `claude-cache-keepalive` | built from `github.com/Banben07/cpa_claude_cache_keep` @ `9b8637d` (Go + gcc) |
| Claude Keep Rolling | `claude-keep-rolling` 0.2.4 | official plugin store |
| API Key Billing | `cpa-key-billing` 1.4.0 | official plugin store |
| 用量统计 | `usage-dashboard-zduu` 2.7.5 | zduu registry (`plugins.store-sources` in config.yaml) |

Check its output; if a plugin failed, re-run `~/cli-proxy-api/install-plugins.sh` (idempotent) and, after a new
`.so` was added, `~/cli-proxy-api/stop.sh` (the watchdog restarts CPA). Verify in the management panel → 插件.
Opt out only if the user asks: `./install.sh --no-plugins`; the list is `CPA_PLUGINS` / `CACHE_KEEPALIVE` in box.env.

### 4. Secrets
```bash
CF_TUNNEL_CREDENTIALS="$CF_TUNNEL_CREDENTIALS" ~/cli-proxy-api/set-tunnel-creds.sh   # writes cloudflared/config.yml
TS_AUTHKEY="$TS_AUTHKEY" ~/tailscale/set-authkey.sh                          # stores authkey (600), runs ensure-up
~/cli-proxy-api/restart-tunnel.sh
```

### 5. Claude login
`~/cli-proxy-api/claude-login.sh start` → open the URL in this box's browser → poll `claude-login.sh status`
until `LOGGED_IN`. Credentials land in `~/cli-proxy-api/auths/`.

### 6. Verify and hand over
`~/cli-proxy-api/healthcheck.sh` must end in `RESULT: OK` (or `FIXED`); `~/cli-proxy-api/status.sh` for an overview.
Give the user: base URL `https://$CF_HOSTNAME` (tailnet: `http://<ts-host>:8317`), the key location
`~/cli-proxy-api/secrets/client-api-key` (show the value once only if asked), and that the management panel is local-only.

### 7. Routine
Create an hourly routine: run `~/cli-proxy-api/healthcheck.sh`; stay silent on `RESULT: OK|FIXED`; on `RESULT: FAILED`
notify the user with the output and the last 30 lines of `~/cli-proxy-api/logs/watchdog.log`. Boot recovery itself is
handled by `boot-services.sh` (autostart) and the two watchdogs, which relaunch each other.

### 8. Point at `cpa-ops` for day-2 operations.
