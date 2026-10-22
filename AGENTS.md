# For bots: start here

Goal: set up a complete grokbot-cpa box (CPA + plugins, Cloudflare tunnel, Tailscale SSH, watchdogs, autostart,
keepalives, AdsPower/RoxyBrowser) with one questionnaire.

1. Read and follow **`skills/grokbot-setup/SKILL.md`** (primary flow: ask once → `./install.sh` → `cf-setup.sh` → Claude login → `selfcheck.sh`).
2. Day-2 operations: `skills/cpa-ops/SKILL.md`.
3. Settings: `box/box.env.example` → `~/.config/grokbot-cpa/box.env`. Only `/home/box` (PERSIST_ROOT) survives reboots.
5. Boot: XDG autostart does NOT fire here. Services come back via the hook in `~/.profile`/`~/.bashrc` (your first Shell after a wake runs `bash -ilc`).
   If services look down, just run `bash ~/boot-services.sh` (idempotent). Optional fallback routine: `@every 10m` → `bash ~/boot-services.sh`.
4. Never print or commit secrets (`secrets/`, `auths/`, `cloudflared/*.json`, `cf-cert.pem`, `tailscale/authkey`, `tailscaled.state`).
