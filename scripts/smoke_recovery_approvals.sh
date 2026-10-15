#!/bin/sh
# Run from the selected umbrella worktree after central compilation/install.
# Prepared unexecuted by the repair author; no compile/build/test lane is invoked.
set -eu
umask 077
MIX_RUNTIME_HOME=${MIX_HOME:-"$HOME/.mix"}
HEX_RUNTIME_HOME=${HEX_HOME:-"$HOME/.hex"}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lemon-approval-recovery.XXXXXX")
mkdir -p "$ROOT/home" "$ROOT/agent" "$ROOT/workspace"
printf 'Isolated approval smoke root: %s\n' "$ROOT"
exec env \
  MIX_ENV=test \
  MIX_HOME="$MIX_RUNTIME_HOME" \
  HEX_HOME="$HEX_RUNTIME_HOME" \
  HOME="$ROOT/home" \
  LEMON_TEST_TMPDIR="$ROOT/home" \
  LEMON_AGENT_DIR="$ROOT/agent" \
  LEMON_LOCK_DIR="$ROOT/locks" \
  LEMON_SMOKE_ROOT="$ROOT" \
  LEMON_HONCHO_ENABLED=false \
  LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=false \
  mix run --no-compile --no-start scripts/smoke_recovery_approvals.exs
