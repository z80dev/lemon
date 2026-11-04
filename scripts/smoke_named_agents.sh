#!/bin/sh
# On-demand only. Run from the integrated umbrella root after central compilation.
# No dependency installation, compile, test, formatter, provider or platform call.
set -eu
umask 077
MIX_RUNTIME_HOME=${MIX_HOME:-"$HOME/.mix"}
HEX_RUNTIME_HOME=${HEX_HOME:-"$HOME/.hex"}
ASDF_RUNTIME_DATA=${ASDF_DATA_DIR:-"$HOME/.asdf"}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lemon-named-agents.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT HUP INT TERM
mkdir -p "$ROOT/home" "$ROOT/agent" "$ROOT/workspace" "$ROOT/tmp" "$ROOT/dotenv"
printf 'Running isolated named-agent smoke (temporary state removed on exit).\n'
# Start from an allowlist, rather than trying to enumerate every provider token.
# PATH/toolchain caches are executable prerequisites, not inherited Lemon config.
env -i \
  PATH="$PATH" \
  LANG="${LANG:-en_US.UTF-8}" \
  MIX_HOME="$MIX_RUNTIME_HOME" \
  HEX_HOME="$HEX_RUNTIME_HOME" \
  ASDF_DATA_DIR="$ASDF_RUNTIME_DATA" \
  MIX_ENV=test \
  HOME="$ROOT/home" \
  TMPDIR="$ROOT/tmp" \
  LEMON_TEST_TMPDIR="$ROOT/home" \
  LEMON_AGENT_DIR="$ROOT/agent" \
  LEMON_DOTENV_DIR="$ROOT/dotenv" \
  LEMON_SMOKE_ROOT="$ROOT" \
  LEMON_NAMED_SMOKE_KEEP_ALIVE="${LEMON_NAMED_SMOKE_KEEP_ALIVE:-0}" \
  LEMON_HONCHO_ENABLED=false \
  LEMON_GATEWAY_HEALTH_PORT=0 \
  LEMON_ROUTER_HEALTH_PORT=0 \
  LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=false \
  mix run --no-compile --no-start scripts/smoke_named_agents.exs
