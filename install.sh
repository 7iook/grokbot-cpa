#!/usr/bin/env bash
# grokbot-cpa installer: CLIProxyAPI + Cloudflare tunnel + watchdog on a Linux box (idempotent).
#
#   TUNNEL_MODE=quick ./install.sh                                    # trial: random trycloudflare URL
#   TUNNEL_MODE=named PUBLIC_URL=https://api.example.com ./install.sh # your own tunnel + hostname
#
# Settings (env vars, all optional; re-running keeps previous values from $INSTALL_DIR/cpa.env unless
# overridden): INSTALL_DIR (~/cli-proxy-api) PORT (8317) METRICS_BASE (20250) AUTH_DIR (~/.cli-proxy-api)
# TUNNEL_MODE (named|quick|none) PUBLIC_URL TUNNEL_PROTOCOL (http2) HOSTS_WORKAROUND (auto|1|0)
# ALLOW_REMOTE (false) CPA_VERSION CLOUDFLARED_VERSION
# Flags: --no-probe (skip edge IP probing)  --reset-config (new config.yaml + new keys)
#        --force (install into an existing directory that was not created by this installer)
set -euo pipefail
CPA_VERSION_PINNED="8.0.4"              # https://github.com/router-for-me/CLIProxyAPI/releases/tag/v8.0.4
CLOUDFLARED_VERSION_PINNED="2026.9.3"   # https://github.com/cloudflare/cloudflared/releases/tag/2026.9.3
declare -A CF_SHA256_PINNED=(           # from the 2026.9.3 release notes
  [amd64]=77e26d8d900e0b8469f416239d14b5f296525fdf79fee6f511ef55609e3fbac2
  [arm64]=aaeb2d7d0da3614634c7e03ab13487a1522c2e79165ed2929cfe23d5e95b326d
)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

NO_PROBE=0; RESET_CONFIG=0; FORCE=0
for a in "$@"; do case "$a" in
  --no-probe) NO_PROBE=1 ;; --reset-config) RESET_CONFIG=1 ;; --force) FORCE=1 ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;; *) die "unknown argument: $a" ;;
esac; done

[[ "$(uname -s)" == Linux ]] || die "only Linux is supported"
for c in curl tar sha256sum openssl awk sed grep getent; do command -v "$c" >/dev/null || die "missing required command: $c"; done

# ---------- settings: env overrides > existing cpa.env > defaults
INSTALL_DIR="${INSTALL_DIR:-$HOME/cli-proxy-api}"; INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
[[ "$INSTALL_DIR" == /* ]] || INSTALL_DIR="$PWD/$INSTALL_DIR"
INSTALL_DIR="${INSTALL_DIR%/}"
case "$INSTALL_DIR" in /|"$HOME"|/usr|/usr/*|/etc|/etc/*|/bin|/sbin|/var|/tmp) die "refusing INSTALL_DIR=$INSTALL_DIR" ;; esac
if [[ -d "$INSTALL_DIR" && ! -f "$INSTALL_DIR/.grokbot-cpa" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" && $FORCE == 0 ]]; then
  die "$INSTALL_DIR exists and was not created by grokbot-cpa (maybe a manual setup). Pick another INSTALL_DIR or pass --force."
fi
VARS=(PORT METRICS_BASE AUTH_DIR TUNNEL_MODE PUBLIC_URL TUNNEL_PROTOCOL HOSTS_WORKAROUND ALLOW_REMOTE CONNECTORS MIN_CONNS CPA_VERSION CLOUDFLARED_VERSION)
declare -A OVR=()
for v in "${VARS[@]}"; do if [[ -n "${!v+x}" ]]; then OVR[$v]="${!v}"; fi; done
# shellcheck disable=SC1091
if [[ -f "$INSTALL_DIR/cpa.env" ]]; then . "$INSTALL_DIR/cpa.env"; fi
for v in "${!OVR[@]}"; do printf -v "$v" '%s' "${OVR[$v]}"; done
PORT="${PORT:-8317}"; METRICS_BASE="${METRICS_BASE:-20250}"
AUTH_DIR="${AUTH_DIR:-$HOME/.cli-proxy-api}"; AUTH_DIR="${AUTH_DIR/#\~/$HOME}"
TUNNEL_MODE="${TUNNEL_MODE:-quick}"; PUBLIC_URL="${PUBLIC_URL:-}"; TUNNEL_PROTOCOL="${TUNNEL_PROTOCOL:-http2}"
HOSTS_WORKAROUND="${HOSTS_WORKAROUND:-auto}"; ALLOW_REMOTE="${ALLOW_REMOTE:-false}"
CONNECTORS="${CONNECTORS:-}"
if [[ -z "$CONNECTORS" ]]; then
  if [[ "$TUNNEL_MODE" == quick ]]; then CONNECTORS=1; else CONNECTORS=2; fi
fi
if [[ -z "${MIN_CONNS:-}" ]]; then
  if [[ "$TUNNEL_MODE" == quick ]]; then MIN_CONNS=1; else MIN_CONNS=2; fi
fi
CPA_VERSION="${CPA_VERSION:-$CPA_VERSION_PINNED}"; CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-$CLOUDFLARED_VERSION_PINNED}"
[[ "$PORT" =~ ^[0-9]+$ && "$METRICS_BASE" =~ ^[0-9]+$ ]] || die "PORT and METRICS_BASE must be numbers"
case "$TUNNEL_MODE" in named|quick|none) ;; *) die "TUNNEL_MODE must be named, quick or none" ;; esac
case "$TUNNEL_PROTOCOL" in http2|quic|auto) ;; *) die "TUNNEL_PROTOCOL must be http2, quic or auto" ;; esac
case "$ALLOW_REMOTE" in true|false) ;; *) die "ALLOW_REMOTE must be true or false" ;; esac
if [[ "$TUNNEL_MODE" == named && -n "$PUBLIC_URL" ]]; then
  [[ "$PUBLIC_URL" == http*://* ]] || PUBLIC_URL="https://$PUBLIC_URL"; PUBLIC_URL="${PUBLIC_URL%/}"
fi
if [[ "$TUNNEL_MODE" == quick ]]; then PUBLIC_URL=""; fi

# ---------- architecture
case "$(uname -m)" in
  x86_64|amd64) CPA_ARCH=amd64; CF_ARCH=amd64 ;;
  aarch64|arm64) CPA_ARCH=aarch64; CF_ARCH=arm64 ;;
  *) die "unsupported CPU architecture: $(uname -m)" ;;
esac
say "install dir $INSTALL_DIR, arch $(uname -m), mode $TUNNEL_MODE, port $PORT"
mkdir -p "$INSTALL_DIR/logs"; chmod 700 "$INSTALL_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
dl() { curl -fsSL --retry 3 --connect-timeout 20 -o "$1" "$2" || die "download failed: $2"; }
place() { install -m 755 "$1" "$INSTALL_DIR/.$2.new" && mv -f "$INSTALL_DIR/.$2.new" "$INSTALL_DIR/$2"; }  # atomic: safe while running
ver_ok() { grep -qx "$1" "$INSTALL_DIR/.versions" 2>/dev/null && [[ -x "$INSTALL_DIR/$2" ]]; }

# ---------- CLIProxyAPI (official release, verified against the release's checksums.txt)
if ver_ok "CPA_VERSION=$CPA_VERSION" cli-proxy-api; then say "CLIProxyAPI $CPA_VERSION already installed"
else
  asset="CLIProxyAPI_${CPA_VERSION}_linux_${CPA_ARCH}.tar.gz"
  base="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${CPA_VERSION}"
  say "downloading $asset"
  dl "$TMP/$asset" "$base/$asset"; dl "$TMP/checksums.txt" "$base/checksums.txt"
  want="$(awk -v f="$asset" '$2 == f || $2 == "*"f {print $1}' "$TMP/checksums.txt")"
  [[ -n "$want" ]] || die "$asset not listed in checksums.txt"
  [[ "$(sha256sum "$TMP/$asset" | awk '{print $1}')" == "$want" ]] || die "checksum mismatch for $asset"
  say "checksum OK"
  mkdir -p "$TMP/cpa"; tar -xzf "$TMP/$asset" -C "$TMP/cpa"
  bin="$(find "$TMP/cpa" -type f -name cli-proxy-api | head -n1)"; [[ -n "$bin" ]] || die "cli-proxy-api not found in $asset"
  place "$bin" cli-proxy-api
  ex="$(find "$TMP/cpa" -type f -name config.example.yaml | head -n1)"; if [[ -n "$ex" ]]; then cp -f "$ex" "$INSTALL_DIR/config.example.yaml"; fi
  lic="$(find "$TMP/cpa" -maxdepth 2 -type f -name LICENSE | head -n1)"; if [[ -n "$lic" ]]; then cp -f "$lic" "$INSTALL_DIR/LICENSE.CLIProxyAPI"; fi
fi

# ---------- cloudflared (official release; SHA256 pinned, or read from the release notes for other versions)
if [[ "$TUNNEL_MODE" == none ]]; then say "TUNNEL_MODE=none: skipping cloudflared"
elif ver_ok "CLOUDFLARED_VERSION=$CLOUDFLARED_VERSION" cloudflared; then say "cloudflared $CLOUDFLARED_VERSION already installed"
else
  asset="cloudflared-linux-$CF_ARCH"
  if [[ "$CLOUDFLARED_VERSION" == "$CLOUDFLARED_VERSION_PINNED" ]]; then want="${CF_SHA256_PINNED[$CF_ARCH]}"
  else
    want="$(curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/tags/$CLOUDFLARED_VERSION" \
      | grep -oE "$asset: [0-9a-f]{64}" | head -n1 | awk '{print $2}')" || true
    [[ -n "$want" ]] || die "no SHA256 for $asset in cloudflared $CLOUDFLARED_VERSION release notes"
  fi
  say "downloading cloudflared $CLOUDFLARED_VERSION ($asset)"
  dl "$TMP/$asset" "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/$asset"
  [[ "$(sha256sum "$TMP/$asset" | awk '{print $1}')" == "$want" ]] || die "checksum mismatch for $asset"
  say "checksum OK"
  place "$TMP/$asset" cloudflared
fi
{ echo "CPA_VERSION=$CPA_VERSION"; if [[ -x "$INSTALL_DIR/cloudflared" ]]; then echo "CLOUDFLARED_VERSION=$CLOUDFLARED_VERSION"; fi; } > "$INSTALL_DIR/.versions"

# ---------- runtime scripts (atomic replace: a running watchdog keeps its old copy)
for f in "$REPO_DIR"/bin/*.sh "$REPO_DIR/uninstall.sh"; do
  n="$(basename "$f")"; cp -f "$f" "$INSTALL_DIR/.$n.new"
  if [[ "$n" == common.sh ]]; then chmod 644 "$INSTALL_DIR/.$n.new"; else chmod 755 "$INSTALL_DIR/.$n.new"; fi
  mv -f "$INSTALL_DIR/.$n.new" "$INSTALL_DIR/$n"
done
say "runtime scripts installed"

# ---------- auth dir + config.yaml
mkdir -p "$AUTH_DIR"; chmod 700 "$AUTH_DIR"
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
if [[ ! -f "$INSTALL_DIR/config.yaml" || $RESET_CONFIG == 1 ]]; then
  API_KEY="sk-cpa-$(openssl rand -hex 24)"; MGMT_SECRET="$(openssl rand -hex 24)"
  tmpl="$(cat "$REPO_DIR/templates/config.yaml.tmpl")"
  tmpl="${tmpl//@PORT@/$PORT}"; tmpl="${tmpl//@AUTH_DIR@/$AUTH_DIR}"; tmpl="${tmpl//@ALLOW_REMOTE@/$ALLOW_REMOTE}"
  tmpl="${tmpl//@API_KEY@/$API_KEY}"; tmpl="${tmpl//@MGMT_SECRET@/$MGMT_SECRET}"
  ( umask 077
    printf '%s\n' "$tmpl" > "$INSTALL_DIR/config.yaml"
    printf '%s\n' "$API_KEY" > "$INSTALL_DIR/API_KEY.txt"
    printf '%s\n' "$MGMT_SECRET" > "$INSTALL_DIR/MANAGEMENT_SECRET.txt" )
  unset API_KEY MGMT_SECRET tmpl
  say "wrote config.yaml with a new random API key (API_KEY.txt) and management secret (MANAGEMENT_SECRET.txt)"
else
  sed -i -E "s|^port:.*|port: $PORT|; s|^auth-dir:.*|auth-dir: \"$(esc "$AUTH_DIR")\"|; s|^(\s*allow-remote:).*|\1 $ALLOW_REMOTE|" "$INSTALL_DIR/config.yaml"
  say "kept existing config.yaml and keys (synced port, auth-dir, allow-remote)"
fi
chmod 600 "$INSTALL_DIR/config.yaml" "$INSTALL_DIR"/API_KEY.txt "$INSTALL_DIR"/MANAGEMENT_SECRET.txt 2>/dev/null || true

# ---------- fake-IP DNS detection -> hosts-file workaround
EDGE_IP="$(getent ahostsv4 region1.v2.argotunnel.com 2>/dev/null | awk 'NR==1{print $1}')"
FAKE_DNS=0; if [[ "$EDGE_IP" =~ ^198\.(18|19)\. ]]; then FAKE_DNS=1; fi
UNSHARE_OK=0; if command -v unshare >/dev/null && unshare --user --map-root-user --mount true 2>/dev/null; then UNSHARE_OK=1; fi
if [[ "$TUNNEL_MODE" == none ]]; then HW=0
else case "$HOSTS_WORKAROUND" in
  1) (( UNSHARE_OK )) || die "HOSTS_WORKAROUND=1 needs 'unshare --user --map-root-user --mount', which does not work here"; HW=1 ;;
  0) HW=0 ;;
  *) if (( FAKE_DNS )); then
       if (( UNSHARE_OK )); then HW=1; say "fake-IP DNS detected (argotunnel -> $EDGE_IP): using per-connector hosts files via unshare"
       else HW=0; warn "fake-IP DNS detected but 'unshare --user' does not work: the tunnel will probably not connect"; fi
     else HW=0; say "DNS looks normal (argotunnel -> ${EDGE_IP:-unresolved}): no hosts workaround needed"; fi ;;
esac; fi

# ---------- cpa.env
q() { printf '%q' "$1"; }
cat > "$INSTALL_DIR/cpa.env" <<ENV
# grokbot-cpa settings (written by install.sh on $(date '+%F %T %Z')). Edit, then restart the affected parts.
INSTALL_DIR=$(q "$INSTALL_DIR")
REPO_DIR=$(q "$REPO_DIR")
PORT=$PORT
METRICS_BASE=$METRICS_BASE
AUTH_DIR=$(q "$AUTH_DIR")
TUNNEL_MODE=$TUNNEL_MODE
PUBLIC_URL=$(q "$PUBLIC_URL")
TUNNEL_PROTOCOL=$TUNNEL_PROTOCOL
HOSTS_WORKAROUND=$HW
ALLOW_REMOTE=$ALLOW_REMOTE
CONNECTORS=$CONNECTORS
MIN_CONNS=$MIN_CONNS
CPA_VERSION=$CPA_VERSION
CLOUDFLARED_VERSION=$CLOUDFLARED_VERSION
ENV
if [[ "$TUNNEL_MODE" == named && -n "$PUBLIC_URL" ]]; then echo "$PUBLIC_URL" > "$INSTALL_DIR/PUBLIC_URL.txt"; fi
echo "grokbot-cpa" > "$INSTALL_DIR/.grokbot-cpa"

# ---------- edge IP probe (only matters with the hosts workaround)
if (( HW )); then
  if (( NO_PROBE )); then say "skipping edge probe (--no-probe; using edge-ips.env or the built-in verified lists)"
  else say "probing Cloudflare edge IPs on :7844"; "$INSTALL_DIR/probe-edges.sh" --write | sed 's/^/    /' || warn "edge probe failed; using built-in verified edge IPs"; fi
fi

# ---------- next steps
D="$INSTALL_DIR"
echo
say "installed. Next steps:"
n=1
if [[ "$TUNNEL_MODE" == named ]]; then
  if [[ ! -s "$D/.tunnel-token" ]]; then echo "  $n. Save your tunnel token:  CF_TUNNEL_TOKEN=... $D/set-tunnel-token.sh"; n=$((n+1)); fi
  if [[ -z "$PUBLIC_URL" ]]; then echo "  $n. Re-run with PUBLIC_URL=https://<your hostname> (routed to http://localhost:$PORT in Cloudflare)"; n=$((n+1)); fi
fi
echo "  $n. Start everything:          $D/start-all.sh"; n=$((n+1))
if ! find "$AUTH_DIR" -maxdepth 1 -name 'claude-*.json' 2>/dev/null | grep -q .; then
  echo "  $n. Log in to Claude:          $D/claude-login.sh start   (open the URL in a browser on this machine)"; n=$((n+1))
fi
echo "  $n. Verify:                    $D/healthcheck.sh"; n=$((n+1))
echo "  $n. Run $D/healthcheck.sh hourly (cron or a bot routine): it is also the start-after-reboot path."
echo "  API key: $D/API_KEY.txt   base URL: $( [[ "$TUNNEL_MODE" == quick ]] && echo "see $D/PUBLIC_URL.txt after start" || echo "${PUBLIC_URL:-http://127.0.0.1:$PORT}" )"
