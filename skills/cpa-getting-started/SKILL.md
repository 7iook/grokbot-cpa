---
name: cpa-getting-started
description: Onboard a new user onto CLIProxyAPI (CPA) with a Cloudflare tunnel on this Grok Bot box. Ask one question at a time, never put secrets in chat, and finish with a working public URL + API key plus an hourly health routine.
---

# CPA getting started

You are helping the user install **CLIProxyAPI (CPA)** on *this* Grok Bot box so they can call Claude through an OpenAI-compatible HTTP API. The install scripts live in the public repo `https://github.com/7iook/grokbot-cpa`. Follow this conversation flow **one question at a time**. Do not dump the whole checklist at once.

## Hard rules

1. **Never** put a tunnel token, API key, management secret, or Claude credential into chat. Use the bot's **secure secret request** (encrypted input) for the Cloudflare tunnel token. After install, tell the user where the key file is (`$INSTALL_DIR/API_KEY.txt`) and show the key only if they ask — and prefer quoting it once, then pointing at the file.
2. **Do not** touch any other install directory you find (especially one without a `.grokbot-cpa` marker). Default install dir is `~/cli-proxy-api`.
3. **Do not** start Claude login in a way that opens a browser on the user's remote machine and then leaves them stuck. Open the OAuth URL in **this box's own browser**.
4. Before any change, tell the user what you will run. Keep the live public URL they already use working if they have one elsewhere.
5. Always mention the **risk notice** once before Claude login (see below).

## Risk notice (say this before Claude OAuth)

> Using a Claude subscription's OAuth outside Claude Code (including through CPA) may violate Anthropic's terms and can lead to account action or 403 errors such as "OAuth not allowed for this organization". Prefer an Anthropic Console API key if you need a ToS-safe path. Continue only if you accept that risk.

## Conversation flow

### 1. Tunnel mode (ask first)

Ask: do they want

- **named** (recommended): their own Cloudflare account + a hostname on a zone they manage in Cloudflare + a **tunnel token**. Stable URL, two connectors, best for daily use.
- **quick** (trial): a random `https://*.trycloudflare.com` URL. No Cloudflare account needed. The URL **changes every time the connector restarts**.

If they are unsure, recommend **named**.

### 2. Collect named-mode inputs (only if named)

Ask for, one at a time:

1. The public hostname they will use (e.g. `https://api.example.com`). Tell them to create a Cloudflare Tunnel in Zero Trust → Networks → Tunnels, point the public hostname at `http://localhost:8317` (or whatever `PORT` they choose), and copy the **tunnel token**.
2. Request the tunnel token via the **secure secret input** (env name `CF_TUNNEL_TOKEN`). Never accept it as a normal chat message. If they already pasted it in chat, tell them to rotate the token in Cloudflare and send the new one through the secure input.

### 3. Install

On this box:

```bash
git clone https://github.com/7iook/grokbot-cpa.git /tmp/grokbot-cpa-src
# or: git -C /tmp/grokbot-cpa-src pull --ff-only
cd /tmp/grokbot-cpa-src

# named:
TUNNEL_MODE=named PUBLIC_URL=https://THEIR_HOST ./install.sh

# quick:
TUNNEL_MODE=quick ./install.sh
```

Optional overrides they may ask about: `INSTALL_DIR`, `PORT` (default 8317), `METRICS_BASE` (default 20250), `AUTH_DIR` (default `~/.cli-proxy-api`).

If named and the token is not stored yet:

```bash
CF_TUNNEL_TOKEN=... "$INSTALL_DIR/set-tunnel-token.sh"
```

(`set-tunnel-token.sh` also accepts a file path or `-` for stdin. It writes `.tunnel-token` with mode 600 and never echoes the token.)

### 4. Start

```bash
"$INSTALL_DIR/start-all.sh"
"$INSTALL_DIR/status.sh"
```

For quick mode, read `$INSTALL_DIR/PUBLIC_URL.txt` after start — that is the temporary public URL.

### 5. Claude login

1. Deliver the risk notice if you have not already.
2. Run: `"$INSTALL_DIR/claude-login.sh" start`
3. Take the printed `https://claude.ai/oauth/authorize?...` URL and **open it in this box's browser**. Ask the user to sign in there.
4. Poll `"$INSTALL_DIR/claude-login.sh" status` until it reports `LOGGED_IN`. Do not ask them to paste cookies. Only use `claude-login.sh paste <callback-url>` if the callback somehow landed on a different machine.
5. Confirm with `"$INSTALL_DIR/healthcheck.sh"` and an authenticated local call:

```bash
KEY=$(head -n1 "$INSTALL_DIR/API_KEY.txt")
curl -sS -H "Authorization: Bearer $KEY" "http://127.0.0.1:${PORT:-8317}/v1/models"
```

An empty `data` list means the service is up but no credential is loaded yet; after a successful login it should list models.

### 6. Hand over credentials

Give the user:

- **Base URL**: named → their `PUBLIC_URL`; quick → contents of `PUBLIC_URL.txt` (warn that it changes on restart).
- **API key location**: `$INSTALL_DIR/API_KEY.txt` (and the key value once if they ask).
- **Management**: bound to localhost with `allow-remote: false` by default. Do not open it to the internet unless they explicitly insist.

Remind them how clients call it (OpenAI-compatible):

```bash
curl -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  "$BASE_URL/v1/chat/completions" \
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hi"}]}'
```

(Exact model ids depend on what their Claude account exposes.)

### 7. Create the hourly routine

Create (or ask the user to approve) an **hourly** routine whose only job is:

> Run `$INSTALL_DIR/healthcheck.sh`. If the last line is `RESULT: OK` or `RESULT: FIXED`, stay silent. If it is `RESULT: FAILED`, notify the user with the full healthcheck output and the last 30 lines of `$INSTALL_DIR/logs/watchdog.log`. Do not restart anything beyond what healthcheck already does. Do not print API keys or tunnel tokens.

This routine is also the **start-after-reboot** path on Grok Bot boxes (no systemd): after a reboot every pid file is stale and `healthcheck.sh` starts whatever is missing.

### 8. Point them at ops

Tell them the companion skill `cpa-ops` covers status, restart, logs, the 530 pattern, upgrades, and the Anthropic 403 meaning.

## Failure handling

- `install.sh` refuses a non-empty directory without `.grokbot-cpa`: pick another `INSTALL_DIR` or pass `--force` only if the user confirms it is safe.
- Fake-IP DNS (`argotunnel` → `198.18.0.0/15`) is detected automatically; the installer enables the hosts-file + `unshare` workaround when possible.
- If quick tunnel public checks flap, remind them this mode is for trials only and switch to named.
