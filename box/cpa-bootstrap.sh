#!/usr/bin/env bash
BOX_ENV="${GROKBOT_BOX_ENV:-$HOME/.config/grokbot-cpa/box.env}"; [ -f "$BOX_ENV" ] && . "$BOX_ENV"   # grokbot-cpa: site settings (see box/box.env.example)
# Idempotent bootstrap for CLIProxyAPI on the box. Safe to re-run after a box reset.
# - reinstalls apt deps (only PERSIST_ROOT=/home/box survives a reset)
# - re-downloads the pinned binary if missing
# - (re)starts the CPA watchdog (which starts CPA + tunnel) if /home/box/cli-proxy-api exists
# Normal boots go through /home/box/boot-services.sh, which calls this only when something is missing.
set -u
CPA_DIR=${CPA_DIR:-$HOME/cli-proxy-api}
CPA_VERSION=${CPA_VERSION:-$(cat $CPA_DIR/VERSION 2>/dev/null || echo v8.0.29)}
SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo"
PKGS="curl jq openssl ca-certificates tar procps iproute2 python3 util-linux"
missing=""; for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
if [ -n "$missing" ]; then echo "installing:$missing"
  $SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq $missing
else echo "deps: all present"; fi
[ -d "$CPA_DIR" ] || { echo "no install at $CPA_DIR; nothing to start"; exit 0; }
# CPA binary source: "source" (default) builds the custom fork, "release" downloads the upstream release.
CPA_BUILD=${CPA_BUILD:-source}
CPA_SOURCE_REPO=${CPA_SOURCE_REPO:-https://github.com/7iook/CLIProxyAPI.git}
CPA_SOURCE_REF=${CPA_SOURCE_REF:-feat/claude-setup-token-quota}   # branch, tag or commit (e.g. 93057ab0)
CPA_SRC_DIR=${CPA_SRC_DIR:-$HOME/build/cpa}
GO_VERSION=${GO_VERSION:-}   # default: the version from the fork's go.mod
build_from_source() {
  command -v git >/dev/null || { $SUDO apt-get install -y -qq git || return 1; }
  if [ -d "$CPA_SRC_DIR/.git" ]; then git -C "$CPA_SRC_DIR" fetch -q origin "$CPA_SOURCE_REF" || return 1
  else git clone -q "$CPA_SOURCE_REPO" "$CPA_SRC_DIR" && git -C "$CPA_SRC_DIR" fetch -q origin "$CPA_SOURCE_REF" || return 1; fi
  git -C "$CPA_SRC_DIR" checkout -q --detach FETCH_HEAD || return 1
  local GO; GO=$(command -v go || echo "$HOME/.local/go/bin/go")
  if [ ! -x "$GO" ]; then
    local gv=${GO_VERSION:-$(awk '/^go /{print $2; exit}' "$CPA_SRC_DIR/go.mod")}
    local ga; case "$(uname -m)" in x86_64) ga=amd64;; aarch64|arm64) ga=arm64;; esac
    mkdir -p "$HOME/.local" && curl -fsSL "https://go.dev/dl/go${gv}.linux-${ga}.tar.gz" | tar xz -C "$HOME/.local" || return 1
    GO="$HOME/.local/go/bin/go"
  fi
  local rev; rev=$(git -C "$CPA_SRC_DIR" rev-parse --short HEAD)
  mkdir -p "$CPA_DIR/bin"
  (cd "$CPA_SRC_DIR" && CGO_ENABLED=0 "$GO" build -trimpath \
    -ldflags "-s -w -X main.Version=${CPA_VERSION}-custom -X main.Commit=$rev -X main.BuildDate=$(date -u +%FT%TZ)" \
    -o "$CPA_DIR/bin/cli-proxy-api.tmp" ./cmd/server) &&
  mv -f "$CPA_DIR/bin/cli-proxy-api.tmp" "$CPA_DIR/bin/cli-proxy-api" && echo "binary built from $CPA_SOURCE_REPO@$CPA_SOURCE_REF ($rev)"
}
if [ ! -x "$CPA_DIR/bin/cli-proxy-api" ] && [ "$CPA_BUILD" = source ]; then
  build_from_source || echo "source build failed; falling back to release $CPA_VERSION"
fi
if [ ! -x "$CPA_DIR/bin/cli-proxy-api" ]; then
  case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=aarch64;; *) echo "unsupported arch"; exit 1;; esac
  V=${CPA_VERSION#v}; F=CLIProxyAPI_${V}_linux_${A}.tar.gz; T=$(mktemp -d)
  curl -fsSL -o "$T/$F" "https://github.com/router-for-me/CLIProxyAPI/releases/download/v$V/$F" &&
  curl -fsSL -o "$T/checksums.txt" "https://github.com/router-for-me/CLIProxyAPI/releases/download/v$V/checksums.txt" &&
  (cd "$T" && grep " $F\$" checksums.txt | sha256sum -c -) && tar xzf "$T/$F" -C "$T" &&
  mkdir -p "$CPA_DIR/bin" && install -m 755 "$T/cli-proxy-api" "$CPA_DIR/bin/cli-proxy-api" && echo "binary reinstalled ($CPA_VERSION)"
  rm -rf "$T"
fi
# cloudflared (tunnel connector) - re-download if missing; credentials/config live in $CPA_DIR/cloudflared
if [ -f "$CPA_DIR/cloudflared/config.yml" ] && [ ! -x "$CPA_DIR/bin/cloudflared" ]; then
  CF_VERSION=${CF_VERSION:-2026.10.0}
  case "$(uname -m)" in x86_64) CA=amd64;; aarch64|arm64) CA=arm64;; esac
  curl -fsSL -o "$CPA_DIR/bin/cloudflared.tmp" "https://github.com/cloudflare/cloudflared/releases/download/$CF_VERSION/cloudflared-linux-$CA" &&
  chmod 755 "$CPA_DIR/bin/cloudflared.tmp" && mv "$CPA_DIR/bin/cloudflared.tmp" "$CPA_DIR/bin/cloudflared" && echo "cloudflared reinstalled ($CF_VERSION)"
fi
# called by boot-services.sh only to (re)install deps/binaries: it starts the services itself
[ -n "${BOOT_SERVICES_CHILD:-}" ] && exit 0
# stale pidfiles after a reset are verified by cmdline in common.sh, so they are harmless
"$CPA_DIR/start-watchdog.sh"   # starts CPA (as its child) and the tunnel within a second
for i in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/8317) 2>/dev/null && break; sleep 0.5; done
"$CPA_DIR/healthcheck.sh" | tail -1
