#!/usr/bin/env bash
# Exercise the real command builders without compiling or starting a runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-cookie.XXXXXX")"
trap 'rm -rf -- "$TEST_DIR"' EXIT

load_function() {
  eval "$(awk -v name="$2" '$0 == name "() {" || $0 == name "() (" {copy=1} copy {print} copy && /^[})]$/ {exit}' "$1")"
}

(
  load_function "$ROOT/bin/lemon" start_runtime
  control_plane_healthy() { return 1; }
  managed_runtime_pidfile() { return 1; }
  control_port_in_use() { return 1; }
  restore_in_progress() { return 1; }
  for fn in acquire_start_lock record_runtime_paths ensure_managed_token load_secrets_master_key compile_source info release_start_lock record_runtime_pid; do
    eval "$fn() { :; }"
  done
  # The final exec is the exact source runtime argv, not a reconstructed model.
  exec() {
    [[ "$RELEASE_COOKIE" == 'private-cookie' ]]
    [[ "$ERL_FLAGS" == *'-setcookie "private-cookie"'* ]]
    [[ "$*" != *private-cookie* && "$*" != *--cookie* ]]
    [[ "$1" == elixir && "$2" == --sname && "$3" == lemon ]]
    exit 0
  }
  LEMON_ROOT="$ROOT" LEMON_HOME_DIR="$TEST_DIR" PIDFILE="$TEST_DIR/pid" ROOTFILE="$TEST_DIR/root"
  NODE_COOKIE=private-cookie NODE_MODE=sname NODE_NAME=lemon DISTRIBUTED=1
  PORT=4040 WEB_PORT=4080 DEBUG='' LAUNCH_CWD="$TEST_DIR"
  start_runtime foreground
)

(
  load_function "$ROOT/rel/overlays/bin/lemon" setup_environment
  load_function "$ROOT/rel/overlays/bin/lemon" release_command
  LEMON_HOME_DIR="$TEST_DIR" STATE_DIR="$TEST_DIR/state"
  RELEASE_COOKIE=private-cookie LEMON_WEB_SECRET_KEY_BASE=already-configured
  setup_environment
  # Release commands inherit RELEASE_COOKIE, with no secret-bearing CLI flag.
  exec() {
    [[ "$RELEASE_COOKIE" == private-cookie ]]
    [[ "$*" != *private-cookie* && "$*" != *--cookie* ]]
    exit 0
  }
  PROFILE=lemon LEMON_ROOT="$TEST_DIR"
  release_command "$TEST_DIR" start
  release_command "$TEST_DIR" remote
)
printf '%s\n' 'launcher cookie command tests passed'
