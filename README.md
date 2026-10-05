# grokbot-cpa

Install and run [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (CPA) on a **Grok Bot** box (or any Linux host) with a Cloudflare tunnel, optional dual connectors, and a health watchdog.

中文说明见下方 [中文](#中文).

> **Risk / 风险:** Using a Claude *subscription* OAuth token outside Claude Code (including through CPA) may violate Anthropic's terms and can lead to account action or upstream `403 OAuth not allowed for this organization`. Prefer an Anthropic Console API key for a ToS-safer setup. You accept this risk by using subscription OAuth here.

## What you get

- Pinned downloads of **CLIProxyAPI v8.0.4** and **cloudflared 2026.9.3** (checksum-verified).
- Local API on `127.0.0.1:8317` (configurable) with a random API key; management API **not** exposed through the tunnel by default.
- Tunnel modes:
  - **named** — your Cloudflare tunnel token + hostname, **2 connectors**, best stability.
  - **quick** — `*.trycloudflare.com` trial URL (changes on restart), 1 connector.
  - **none** — local only.
- Fake-IP DNS detection (common on Grok Bot boxes): per-connector `/etc/hosts` via `unshare`, with TLS-probed edge IPs.
- Watchdog that restarts unhealthy connectors one at a time; on public HTTP 530 it restarts all connectors at once (30s cooldown).
- `healthcheck.sh` as the hourly / post-reboot recovery path (no systemd required).

## Architecture

```
Clients ──HTTPS──► Cloudflare edge ──tunnel──► cloudflared (1 or 2 connectors)
                                                      │
                                                      ▼
                                              CLIProxyAPI :PORT
                                                      │
                                                      ▼
                                              Claude OAuth / API
```

On hosts whose DNS maps `*.argotunnel.com` into `198.18.0.0/15`, each connector runs in a user+mount namespace with a private hosts file listing real edge IPs so HA connections can form.

## Quick start

### Via Grok Bot template (recommended)

> Template link: **(placeholder — paste the public Grok Bot template URL here once published)**

Add the template bot, then follow the `cpa-getting-started` skill (it asks one question at a time, takes the tunnel token through secure input, installs, runs Claude login in the box browser, and creates the hourly routine).

### Manual

```bash
git clone https://github.com/7iook/grokbot-cpa.git
cd grokbot-cpa

# Trial (random trycloudflare URL):
TUNNEL_MODE=quick ./install.sh

# Stable (your hostname + tunnel token):
TUNNEL_MODE=named PUBLIC_URL=https://api.example.com ./install.sh
CF_TUNNEL_TOKEN=... ./bin/set-tunnel-token.sh   # after install, from $INSTALL_DIR

"$HOME/cli-proxy-api/start-all.sh"
"$HOME/cli-proxy-api/claude-login.sh" start   # open the URL on this machine
"$HOME/cli-proxy-api/healthcheck.sh"
```

Settings (`INSTALL_DIR`, `PORT`, `METRICS_BASE`, `AUTH_DIR`, `TUNNEL_MODE`, …) are documented in `cpa.env.example` and written to `$INSTALL_DIR/cpa.env`.

## Requirements

- Linux (amd64 or arm64), `bash`, `curl`, `tar`, `openssl`, `python3` optional.
- For the hosts workaround: `unshare --user --map-root-user --mount` (usually available).
- Named mode: Cloudflare account, zone, tunnel token, hostname routed to `http://localhost:$PORT`.
- A Claude account you are willing to OAuth-login on this host (see risk notice).

## Layout after install

```
$INSTALL_DIR/
  cli-proxy-api  cloudflared
  config.yaml  API_KEY.txt  MANAGEMENT_SECRET.txt  cpa.env
  start-all.sh stop-all.sh status.sh healthcheck.sh
  start-tunnel.sh watchdog.sh claude-login.sh ...
  logs/
```

## Credits

- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) — MIT License
- [cloudflared](https://github.com/cloudflare/cloudflared) — Apache-2.0

This repository is MIT (`LICENSE`). It ships **no** binaries; `install.sh` downloads official releases.

---

## 中文

在 **Grok Bot** 电脑（或任意 Linux）上安装 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)，并用 Cloudflare 隧道把 API 暴露出去；带双连接、健康检查看门狗，以及重启后自动恢复。

> **风险提示：** 在 Claude Code 之外使用订阅账号的 OAuth（包括经 CPA 转发）可能违反 Anthropic 条款，存在封号或上游返回 `403 OAuth not allowed for this organization` 的风险。更稳妥的做法是改用 Anthropic Console 的 API key。继续使用即表示你接受该风险。

### 你能得到什么

- 固定版本下载并校验：**CLIProxyAPI v8.0.4**、**cloudflared 2026.9.3**
- 本机 `127.0.0.1:8317`（可改）随机 API 密钥；管理面板默认不对公网开放
- 隧道模式：`named`（自有域名 + token，双连接）、`quick`（临时 trycloudflare 地址）、`none`
- 自动检测假 IP DNS，必要时用 `unshare` + 私有 hosts + 探测边缘 IP
- 看门狗按连接健康状态逐个重启；公网 530 时立刻重启全部连接器（30 秒冷却）
- `healthcheck.sh` 可作为每小时巡检与开机恢复（无需 systemd）

### 快速开始

**Grok Bot 模板（推荐）：** 模板链接占位（发布后贴到此处）。添加模板机器人后按 `cpa-getting-started` 技能引导即可（隧道 token 走加密输入，不在聊天里粘贴）。

**手动：**

```bash
git clone https://github.com/7iook/grokbot-cpa.git && cd grokbot-cpa
TUNNEL_MODE=quick ./install.sh          # 试用
# 或：TUNNEL_MODE=named PUBLIC_URL=https://api.example.com ./install.sh
"$HOME/cli-proxy-api/start-all.sh"
"$HOME/cli-proxy-api/claude-login.sh" start
"$HOME/cli-proxy-api/healthcheck.sh"
```

更多选项见 `cpa.env.example`。运维与排障见技能 `cpa-ops`。

### 致谢

CLIProxyAPI（MIT）、cloudflared（Apache-2.0）。本仓库本身为 MIT，不包含二进制，由 `install.sh` 从官方 Release 下载。
