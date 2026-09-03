#!/usr/bin/env bash
#
# Cloud Agent install script for the Lemon Elixir umbrella.
#
# Idempotent: installs the exact BEAM toolchain pinned in .tool-versions
# (Erlang/OTP + Elixir) via asdf, Bun for the TUI client, fetches and compiles
# the umbrella, and installs TUI dependencies. Safe to run repeatedly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { printf '\033[0;32m[install]\033[0m %s\n' "$1"; }

# --- System build dependencies (Erlang builds from source via kerl) ----------
log "Installing system build dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential autoconf m4 \
  libncurses-dev libssl-dev libssh-dev unixodbc-dev libgmp-dev \
  inotify-tools curl git unzip

# --- asdf --------------------------------------------------------------------
export ASDF_DATA_DIR="$HOME/.asdf"
export PATH="$ASDF_DATA_DIR/shims:/usr/local/bin:$PATH"

if ! command -v asdf >/dev/null 2>&1; then
  log "Installing asdf"
  ASDF_VERSION="v0.18.0"
  curl -fsSL -o /tmp/asdf.tar.gz \
    "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-amd64.tar.gz"
  tar -xzf /tmp/asdf.tar.gz -C /tmp
  sudo mv /tmp/asdf /usr/local/bin/asdf
  rm -f /tmp/asdf.tar.gz
fi

# Persist toolchain paths for future login shells and terminals.
if ! grep -q 'ASDF_DATA_DIR' "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'RC'

# Lemon dev toolchain (asdf-managed Erlang/Elixir + Bun)
export ASDF_DATA_DIR="$HOME/.asdf"
export BUN_INSTALL="$HOME/.bun"
export PATH="$ASDF_DATA_DIR/shims:/usr/local/bin:$BUN_INSTALL/bin:$PATH"
RC
fi

log "Adding asdf plugins"
asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git 2>/dev/null || true
asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git 2>/dev/null || true

# Headless Erlang build: skip GUI/JVM/docs to keep the build fast and dependency-light.
export KERL_CONFIGURE_OPTIONS="--without-wx --without-javac --without-observer --without-debugger --without-et --disable-docs"
export KERL_BUILD_DOCS="no"

log "Installing Erlang/Elixir from .tool-versions (this compiles Erlang; ~2 min)"
asdf install

# --- Hex / Rebar -------------------------------------------------------------
log "Installing Hex and Rebar"
mix local.hex --force
mix local.rebar --force

# --- Umbrella dependencies + compile ----------------------------------------
log "Fetching and compiling umbrella dependencies"
mix deps.get
mix compile

# --- Bun + TUI client dependencies ------------------------------------------
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
BUN_VERSION="$(cat clients/tui/.bun-version)"
if [ "$(bun --version 2>/dev/null || true)" != "$BUN_VERSION" ]; then
  log "Installing Bun ${BUN_VERSION}"
  curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}"
fi

log "Installing TUI client dependencies"
(cd clients/tui && bun install --frozen-lockfile)

log "Environment setup complete"
