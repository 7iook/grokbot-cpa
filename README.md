# grokbot-cpa

Install and run [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (CPA) on a **Grok Bot** box with a named
Cloudflare tunnel, Tailscale, two watchdogs that relaunch each other, boot autostart and optional keepalives.
CPA is built from the fork **[7iook/CLIProxyAPI](https://github.com/7iook/CLIProxyAPI)** (`feat/claude-setup-token-quota`) by default.

**Bots: start with [`AGENTS.md`](AGENTS.md) → [`skills/grokbot-setup`](skills/grokbot-setup/SKILL.md).** Everything is installed by default; only `/home/box` persists across reboots, so all state lives there.

中文说明见下方 [中文](#中文).

> **Risk notice:** using a Claude subscription's OAuth outside Claude Code (including through CPA) may violate
> Anthropic's terms (403 "OAuth not allowed for this organization", account action). An Anthropic Console API key is safer.

## Layout

```
install.sh              entry point (calls box/install-box.sh, writes config.yaml + secrets/, starts services)
uninstall.sh            stop + remove autostart (--purge deletes install dirs)
box/box.env.example     all settings -> ~/.config/grokbot-cpa/box.env
box/cpa/                CPA watchdog v2 + start/stop/status/healthcheck/tunnel/claude-login/... -> $CPA_DIR
box/tailscale/          ensure-up.sh, watchdog.sh, lib.sh, set-authkey.sh -> $TS_DIR
box/boot-services.sh    boot hook (XFCE autostart; no systemd/cron on the box) -> ~/boot-services.sh
box/cpa-bootstrap.sh    deps + CPA binary (source build or release) after a box reset -> ~/cpa-bootstrap.sh
box/autostart/          .desktop templates
box/browsers/          install-adspower.sh, install-roxy.sh (extracted .deb under PERSIST_ROOT)
box/selfcheck.sh       PASS/FAIL self-check -> ~/grokbot-cpa-bin/
keepalive/cmcc/         installs github.com/1936-zero/cmcc-cloud-alive WebUI + supervisor (default on; --no-cmcc)
keepalive/box-activity/ browse loop + monitor that keep the box active (default on; --no-activity)
templates/config.yaml.tmpl
skills/                 cpa-getting-started, cpa-ops (Grok Bot skills)
```

## Install

```bash
git clone https://github.com/7iook/grokbot-cpa.git ~/grokbot-cpa && cd ~/grokbot-cpa
CF_HOSTNAME=api.example.com TS_HOSTNAME=cpa-box TS_AUTHKEY=... ./install.sh   # all on; --no-tunnel/--no-tailscale/--no-plugins/--no-browsers/--no-cmcc/--no-activity
~/cli-proxy-api/cf-setup.sh login   # open the URL, authorize; then:
~/cli-proxy-api/cf-setup.sh setup   # create/reuse tunnel, route DNS, start
# alternative to cf-setup (existing credentials JSON):
CF_TUNNEL_CREDENTIALS_FILE=./<tunnel-id>.json ~/cli-proxy-api/set-tunnel-creds.sh && ~/cli-proxy-api/restart-tunnel.sh
TS_AUTHKEY=tskey-auth-... ~/tailscale/set-authkey.sh
~/cli-proxy-api/claude-login.sh start        # open the URL in this box's browser
~/grokbot-cpa-bin/selfcheck.sh             # SELFCHECK: PASS
```

CPA source: `CPA_SOURCE_REPO` / `CPA_SOURCE_REF` (branch, tag or commit) in box.env.
Official release binary instead: `CPA_BUILD=release CPA_VERSION=v8.0.29 ./install.sh`.

### Plugins

Right after CPA starts, `install.sh` runs `$CPA_DIR/install-plugins.sh` (idempotent; skip with `--no-plugins`):
缓存保活 `claude-cache-keepalive` (built from [Banben07/cpa_claude_cache_keep](https://github.com/Banben07/cpa_claude_cache_keep), needs Go + gcc),
Claude Keep Rolling `claude-keep-rolling`, API Key Billing `cpa-key-billing` (official store) and 用量统计 `usage-dashboard-zduu`
(zduu registry) via the management API `POST /v0/management/plugin-store/<id>/install`. Lamplighter is not installed.
Configure with `CPA_PLUGINS` / `CACHE_KEEPALIVE*` in box.env.

### Where secrets live

| Secret | Path |
|---|---|
| client API key (Bearer) | `$CPA_DIR/secrets/client-api-key` (+ `api-keys` in `config.yaml`) |
| management secret | `$CPA_DIR/secrets/management-secret` |
| Claude / provider OAuth | `$CPA_DIR/auths/*.json` |
| Cloudflare login cert | `$CPA_DIR/secrets/cf-cert.pem` |
| tunnel credentials | `$CPA_DIR/cloudflared/<tunnel-id>.json` |
| Tailscale auth key / node state | `$TS_DIR/authkey`, `$TS_DIR/tailscaled.state` (root, 600) |

## Operations

`status.sh`, `healthcheck.sh`, `start-watchdog.sh`, `stop-all.sh`, `restart-tunnel.sh`, `claude-login.sh` in `$CPA_DIR`;
logs in `$CPA_DIR/logs/` and `$TS_DIR/*.log`. See `skills/cpa-ops/SKILL.md`.

## Credits

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (MIT), [cloudflared](https://github.com/cloudflare/cloudflared) (Apache-2.0),
[cmcc-cloud-alive](https://github.com/1936-zero/cmcc-cloud-alive) (MIT). This repo is MIT and ships no binaries.

---

## 中文

在 Grok Bot 电脑上部署 CPA：命名 Cloudflare 隧道 + Tailscale + 两个互相拉起的看门狗 + 开机自启（XFCE autostart）+ 可选保活。
CPA 默认从 `7iook/CLIProxyAPI` 的 `feat/claude-setup-token-quota` 分支源码编译（`CPA_BUILD=release` 改用官方发行版）。

- 配置：`~/.config/grokbot-cpa/box.env`（模板 `box/box.env.example`），不放任何密钥。
- 安装：`./install.sh`（默认全装，可用 --no-* 跳过），之后用 `set-tunnel-creds.sh`（隧道凭据）、`TS_AUTHKEY=... set-authkey.sh`（Tailscale）、`claude-login.sh start`（Claude 登录）。
- 密钥位置见上表；客户端 key 在 `~/cli-proxy-api/secrets/client-api-key`。
- 插件：安装后自动装 缓存保活、Claude Keep Rolling、API Key Billing、用量统计（不装 Lamplighter），`--no-plugins` 可跳过，重装用 `install-plugins.sh`。
- 入口：机器人先读 `AGENTS.md` → `skills/grokbot-setup`（一次问齐，全部默认安装，最后 `selfcheck.sh`）。只有 `/home/box` 重启后保留，所有文件都放在那里，apt 包由 boot-services.sh 开机补装。
- 指纹浏览器：AdsPower、RoxyBrowser 解包安装到 `~/adspower`、`~/roxybrowser`。
- 运维：`status.sh` / `healthcheck.sh` / `start-watchdog.sh` / `stop-all.sh` / `restart-tunnel.sh`，详见技能 `cpa-ops`。
