# grokbot-cpa

Install and run [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (CPA) on a **Grok Bot** box with a named
Cloudflare tunnel, Tailscale, two watchdogs that relaunch each other, boot autostart (with swap) and optional keepalives,
plus an optional **3X-UI** panel (VLESS-WS node + subscriptions) behind its own Cloudflare tunnel.
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
box/3x-ui/              3X-UI v3.11.0: install.sh, watchdog.sh, start/stop/status, tunnel.sh, cf-setup.sh, api.py -> $XUI_DIR
box/boot-services.sh    boot hook -> ~/boot-services.sh (fired by ~/.profile/~/.bashrc hook; waits for home restore; swap + all supervisors)
box/install-hooks.sh    writes/checks the marked boot hook blocks in ~/.profile + ~/.bashrc
box/cpa-bootstrap.sh    deps + CPA binary (source build or release) after a box reset -> ~/cpa-bootstrap.sh
box/autostart/          .desktop templates (compat only: XDG autostart does not fire on a Grok Bot box)
box/browsers/          install-adspower.sh, install-roxy.sh (extracted .deb under PERSIST_ROOT)
box/selfcheck.sh       PASS/FAIL self-check -> ~/grokbot-cpa-bin/
keepalive/cmcc/         installs github.com/1936-zero/cmcc-cloud-alive WebUI + supervisor (default on; --no-cmcc)
keepalive/box-activity/ browse loop + monitor that keep the box active (default on; --no-activity)
templates/config.yaml.tmpl, templates/3x-ui-cloudflared.yml.tmpl
skills/                 cpa-getting-started, cpa-ops (Grok Bot skills)
```

## Install

```bash
git clone https://github.com/7iook/grokbot-cpa.git ~/grokbot-cpa && cd ~/grokbot-cpa
CF_HOSTNAME=api.example.com TS_HOSTNAME=cpa-box TS_AUTHKEY=... \
  XUI_CF_HOSTNAME=3x.example.com XUI_SUB_HOSTNAME=sub3x.example.com XUI_NODE_HOSTNAME=node3x.example.com \
  ./install.sh   # all on; --no-tunnel/--no-tailscale/--no-plugins/--no-browsers/--no-cmcc/--no-activity/--no-3xui
~/cli-proxy-api/cf-setup.sh login   # open the URL, authorize; then:
~/cli-proxy-api/cf-setup.sh setup   # create/reuse tunnel, route DNS, start
~/3x-ui/cf-setup.sh setup           # 3X-UI's own tunnel (same Cloudflare cert), 3 hostnames
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
| 3X-UI panel login (+ sub path) | `$XUI_DIR/secrets/panel.env` (XUI_USER, XUI_PASS, XUI_PATH, XUI_SUBPATH) |
| 3X-UI node ids (WS path, client UUID, sub id) | `$XUI_DIR/secrets/node.env` |
| 3X-UI tunnel credentials / DB | `$XUI_DIR/cloudflared/<tunnel-id>.json`, `$XUI_DIR/db/x-ui.db` (+ `backups/`) |

### 3X-UI

`box/3x-ui/install.sh` (run by `install.sh`, skip with `--no-3xui`) installs [3X-UI](https://github.com/MHSanaei/3x-ui)
`XUI_VERSION` (v3.11.0) into `$XUI_DIR` (`~/3x-ui`, box-owned so it survives a VM swap), all on 127.0.0.1:

| Port | What | Public host (its own tunnel `XUI_CF_TUNNEL`) |
|---|---|---|
| `XUI_PANEL_PORT` 20530 | panel, `webBasePath /` | `XUI_CF_HOSTNAME` |
| `XUI_SUB_PORT` 20531 | subscription server (plain / JSON / Clash paths, random) | `XUI_SUB_HOSTNAME` |
| `XUI_NODE_PORT` 20532 | one VLESS + WebSocket inbound (clients: TLS 443 at the node host) | `XUI_NODE_HOSTNAME` |

Login and node ids are random on first install (override once with `XUI_ADMIN_USER` / `XUI_ADMIN_PASS`) and stored only in
`$XUI_DIR/secrets/`. Re-running `install.sh` is idempotent (keeps DB, secrets, inbounds; re-applies ports/listen/sub URLs;
upgrades the app when `XUI_VERSION` changes, DB copied to `backups/` first). `$XUI_DIR/watchdog.sh` runs x-ui as its child
(crash restart with backoff, hang kill after 6 failed checks once it answered or 90s after start, never while
MemAvailable < 1024 MB), keeps the 3X-UI tunnel healthy (dead / not ready / public 5xx / VM resume) and backs the DB up
daily (sqlite online backup, keep 7). It is started by `boot-services.sh` and relaunched by the Tailscale watchdog.
`$XUI_DIR/api.py get|post|form <path>` calls the panel API locally (CSRF token + login from `secrets/panel.env`).

### Memory guard and swap

A box filled by AdsPower (16 GB, no swap) once made CPA too slow to answer and the watchdogs killed it in a loop. Now
`boot-services.sh` (re)creates and enables `BOOT_SWAP_FILE` (`/swapfile`, `BOOT_SWAP_SIZE` 8G, `0` = off) on every wake
(root-owned system state is lost on a VM swap), and every watchdog (CPA, Tailscale "unanswering", 3X-UI, cmcc) only logs
instead of hang-killing while MemAvailable < `MEM_GUARD_MB` (1024). The CPA watchdog also re-syncs its child every tick
(adopts a CPA started by `start.sh`, notices a child that was already reaped) instead of spinning on `wait`.
Nothing kills other apps (e.g. AdsPower) for memory: that stays a manual decision.

### Management panel

`config.yaml` points the panel at the [7iook/Cli-Proxy-API-Management-Center](https://github.com/7iook/Cli-Proxy-API-Management-Center)
fork and sets `disable-auto-update-panel: true`: a missing `static/management.html` is still fetched from the fork's latest
release, but it is never re-downloaded in the background (that would overwrite a hand-deployed build).

## Operations

`status.sh`, `healthcheck.sh`, `start-watchdog.sh`, `stop-all.sh`, `restart-tunnel.sh`, `claude-login.sh` in `$CPA_DIR`;
`status.sh`, `start.sh`, `stop.sh`, `tunnel.sh`, `cf-setup.sh`, `api.py` in `$XUI_DIR`;
logs in `$CPA_DIR/logs/`, `$TS_DIR/*.log`, `$XUI_DIR/logs/`. See `skills/cpa-ops/SKILL.md`.

## Credits

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (MIT), [cloudflared](https://github.com/cloudflare/cloudflared) (Apache-2.0),
[cmcc-cloud-alive](https://github.com/1936-zero/cmcc-cloud-alive) (MIT), [3X-UI](https://github.com/MHSanaei/3x-ui) (GPL-3.0, downloaded at install time). This repo is MIT and ships no binaries.

---

## Boot trigger
Boot trigger on a Grok Bot box: there is no systemd/cron and the desktop is only a window manager, so XDG autostart (`~/.config/autostart/*.desktop`, kept for compat) does **not** fire. The chain is: bot wakes → first agent Shell → exec-daemon initializes it with `bash -ilc` → `~/.profile`/`~/.bashrc` → marked `grokbot-cpa boot hook` block (written by `box/install-hooks.sh`) → `~/boot-services.sh` (waits for the home restore `/tmp/sand-copy-in-status.json`, then starts only supervisors whose lock is free). Optional fallback: Grok Bot routine `@every 10m` → `bash ~/boot-services.sh`. After a VM swap the SSH host key changes (`ssh-keygen -R <ip>`).

## 中文

在 Grok Bot 电脑上部署 CPA：命名 Cloudflare 隧道 + Tailscale + 两个互相拉起的看门狗 + 开机自启（`~/.profile`/`~/.bashrc` 钩子：bot 唤醒 → 首个 Shell 以 `bash -ilc` 初始化 → 钩子 → `boot-services.sh`；XDG autostart 在此类 VM 上不触发，仅保留兼容；可选兜底 routine `@every 10m` 执行 `bash ~/boot-services.sh`；换 VM 后 SSH 主机密钥会变）+ 可选保活。
CPA 默认从 `7iook/CLIProxyAPI` 的 `feat/claude-setup-token-quota` 分支源码编译（`CPA_BUILD=release` 改用官方发行版）。

- 配置：`~/.config/grokbot-cpa/box.env`（模板 `box/box.env.example`），不放任何密钥。
- 安装：`./install.sh`（默认全装，可用 --no-* 跳过），之后用 `set-tunnel-creds.sh`（隧道凭据）、`TS_AUTHKEY=... set-authkey.sh`（Tailscale）、`claude-login.sh start`（Claude 登录）。
- 密钥位置见上表；客户端 key 在 `~/cli-proxy-api/secrets/client-api-key`。
- 插件：安装后自动装 缓存保活、Claude Keep Rolling、API Key Billing、用量统计（不装 Lamplighter），`--no-plugins` 可跳过，重装用 `install-plugins.sh`。
- 入口：机器人先读 `AGENTS.md` → `skills/grokbot-setup`（一次问齐，全部默认安装，最后 `selfcheck.sh`）。只有 `/home/box` 重启后保留，所有文件都放在那里，apt 包由 boot-services.sh 开机补装。
- 指纹浏览器：AdsPower、RoxyBrowser 解包安装到 `~/adspower`、`~/roxybrowser`。
- 3X-UI（默认安装，`--no-3xui` 跳过）：v3.11.0 装在 `~/3x-ui`（box 用户所有，换 VM 不丢），面板 20530（webBasePath `/`）、订阅 20531、VLESS-WS 节点 20532，全部只监听 127.0.0.1，经自己的 Cloudflare 隧道 `grokbot-3xui` 暴露（域名填 box.env 的 `XUI_CF_HOSTNAME` / `XUI_SUB_HOSTNAME` / `XUI_NODE_HOSTNAME`，`~/3x-ui/cf-setup.sh setup` 复用 CPA 的 Cloudflare 授权）。账号密码首次随机生成，只存在 `~/3x-ui/secrets/`。看门狗负责崩溃重启、卡死重启、隧道自愈、每日数据库备份（保留 7 份），由 boot-services 开机拉起、Tailscale 看门狗兜底。`~/3x-ui/api.py` 带 CSRF 登录调用面板 API。
- 内存保护：boot-services 每次唤醒重建并启用 8G `/swapfile`（`BOOT_SWAP_SIZE=0` 关闭）；所有看门狗在 MemAvailable < 1024MB 时只记日志、不杀进程（避免内存紧张时误杀 CPA 形成重启循环）；不会自动杀其他应用（如 AdsPower）。
- 面板：config.yaml 使用 7iook 管理面板 fork，`disable-auto-update-panel: true`（缺失时仍会首次下载，但不会后台覆盖手动部署的 management.html）。
- 运维：`status.sh` / `healthcheck.sh` / `start-watchdog.sh` / `stop-all.sh` / `restart-tunnel.sh`；3X-UI 用 `~/3x-ui/status.sh|start.sh|stop.sh`，详见技能 `cpa-ops`。
