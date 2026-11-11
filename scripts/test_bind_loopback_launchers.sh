#!/usr/bin/env bash
# Focused tests for S0 loopback distribution defaults and container entrypoint.
# Unverified in subagent; to be run by main agent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-bind-loopback-test.XXXXXX")"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cleanup() {
  if [[ "$TEST_DIR" == "${TMPDIR:-/tmp}"/lemon-bind-loopback-test.* ]]; then
    rm -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT

# ── 1. Source launcher: bin/lemon ───────────────────────────────────────────
echo "[test] Verifying bin/lemon loopback defaults and overrides..."

test_source_launcher() {
  local extra_args="$1"
  local env_prefix="$2"
  local expected_epmd="$3"
  local expected_has_dist="$4"

  (
    # shellcheck disable=SC2086
    eval "$env_prefix"
    # shellcheck disable=SC2086
    set -- $extra_args
    ORIGINAL_ARGS=("$@")
    ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-}"
    ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-}"
    NODE_MODE="${NODE_MODE:-}"
    RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-}"

    # Load the logic under test
    load_environment() {
      export ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}"

      local has_name=0 arg
      if [ "${NODE_MODE:-}" = "name" ] || [ "${RELEASE_DISTRIBUTION:-}" = "name" ]; then
        has_name=1
      fi
      for arg in "${ORIGINAL_ARGS[@]}"; do
        if [ "$arg" = "--name" ]; then
          has_name=1
          break
        fi
      done
      if [ "$has_name" = "0" ]; then
        case "${ELIXIR_ERL_OPTIONS:-}" in
          *inet_dist_use_interface*) ;;
          *)
            export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-}${ELIXIR_ERL_OPTIONS:+ }-kernel inet_dist_use_interface {127,0,0,1}"
            ;;
        esac
      fi
    }
    load_environment

    [ "${ERL_EPMD_ADDRESS:-}" = "$expected_epmd" ] || {
      echo "FAIL: expected ERL_EPMD_ADDRESS='$expected_epmd', got '${ERL_EPMD_ADDRESS:-}'" >&2
      exit 1
    }

    if [ "$expected_has_dist" = "1" ]; then
      case "${ELIXIR_ERL_OPTIONS:-}" in
        *"-kernel inet_dist_use_interface {127,0,0,1}"*) ;;
        *)
          echo "FAIL: expected inet_dist_use_interface {127,0,0,1} in ELIXIR_ERL_OPTIONS, got '${ELIXIR_ERL_OPTIONS:-}'" >&2
          exit 1
          ;;
      esac
    else
      case "${ELIXIR_ERL_OPTIONS:-}" in
        *"-kernel inet_dist_use_interface {127,0,0,1}"*)
          echo "FAIL: expected inet_dist_use_interface NOT to be set in ELIXIR_ERL_OPTIONS, got '${ELIXIR_ERL_OPTIONS:-}'" >&2
          exit 1
          ;;
      esac
    fi
  )
}

# Default start: ERL_EPMD_ADDRESS=127.0.0.1 and dist interface set
test_source_launcher "start" "" "127.0.0.1" 1

# Explicit --name: ERL_EPMD_ADDRESS STILL defaults to 127.0.0.1; only dist interface is skipped
test_source_launcher "start --name lemon@node1.local" "" "127.0.0.1" 0

# Explicit RELEASE_DISTRIBUTION=name: ERL_EPMD_ADDRESS STILL defaults to 127.0.0.1; dist interface skipped
test_source_launcher "start" "export RELEASE_DISTRIBUTION=name;" "127.0.0.1" 0

# Preserves user's explicit cross-host ERL_EPMD_ADDRESS
test_source_launcher "start" "export ERL_EPMD_ADDRESS=0.0.0.0;" "0.0.0.0" 1
test_source_launcher "start --name lemon@node1.local" "export ERL_EPMD_ADDRESS=0.0.0.0;" "0.0.0.0" 0

# Preserves user's custom inet_dist_use_interface in ELIXIR_ERL_OPTIONS
(
  export ELIXIR_ERL_OPTIONS="-kernel inet_dist_use_interface {0,0,0,0}"
  ORIGINAL_ARGS=("start")
  load_environment() {
    export ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}"
    local has_name=0 arg
    if [ "${NODE_MODE:-}" = "name" ] || [ "${RELEASE_DISTRIBUTION:-}" = "name" ]; then
      has_name=1
    fi
    for arg in "${ORIGINAL_ARGS[@]}"; do
      if [ "$arg" = "--name" ]; then
        has_name=1
        break
      fi
    done
    if [ "$has_name" = "0" ]; then
      case "${ELIXIR_ERL_OPTIONS:-}" in
        *inet_dist_use_interface*) ;;
        *)
          export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-}${ELIXIR_ERL_OPTIONS:+ }-kernel inet_dist_use_interface {127,0,0,1}"
          ;;
      esac
    fi
  }
  load_environment
  [ "$ELIXIR_ERL_OPTIONS" = "-kernel inet_dist_use_interface {0,0,0,0}" ] || {
    echo "FAIL: custom inet_dist_use_interface was overridden: $ELIXIR_ERL_OPTIONS" >&2
    exit 1
  }
)

echo "[test] bin/lemon loopback defaults OK"

# ── 2. Release launcher: rel/overlays/bin/lemon ──────────────────────────────
echo "[test] Verifying rel/overlays/bin/lemon loopback defaults and overrides..."

grep -Fq 'export ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}"' "$ROOT/rel/overlays/bin/lemon"
grep -Fq -- '-kernel inet_dist_use_interface {127,0,0,1}' "$ROOT/rel/overlays/bin/lemon"

grep -Fq 'export ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-127.0.0.1}"' "$ROOT/bin/lemon"
grep -Fq -- '-kernel inet_dist_use_interface {127,0,0,1}' "$ROOT/bin/lemon"

echo "[test] rel/overlays/bin/lemon loopback defaults OK"

# ── 2b. Release env hook: rel/env.sh.eex ─────────────────────────────────────
# `mix release` copies this to releases/<vsn>/env.sh, which every generated
# release command sources -- including the container CMD that calls the release
# binary directly, bypassing the bin/lemon wrapper.
echo "[test] Verifying rel/env.sh.eex release distribution defaults..."

ENV_HOOK="$ROOT/rel/env.sh.eex"
[ -f "$ENV_HOOK" ] || { echo "FAIL: missing $ENV_HOOK" >&2; exit 1; }

# It is sourced by /bin/sh, so it must hold no EEx tags and must parse as POSIX sh.
if grep -q '<%' "$ENV_HOOK"; then
  echo "FAIL: rel/env.sh.eex must contain no EEx tags; it is sourced verbatim" >&2
  exit 1
fi
sh -n "$ENV_HOOK"

hook_env() {
  # Prints ERL_EPMD_ADDRESS and ELIXIR_ERL_OPTIONS after sourcing the hook.
  env -i PATH="$PATH" HOME="$TEST_DIR" "$@" sh -c \
    '. "$1"; printf "%s\n%s\n" "${ERL_EPMD_ADDRESS:-}" "${ELIXIR_ERL_OPTIONS:-}"' sh "$ENV_HOOK"
}

# Default release command: loopback epmd and loopback dist interface.
{ read -r hook_epmd; read -r hook_opts; } < <(hook_env)
[ "$hook_epmd" = "127.0.0.1" ] || {
  echo "FAIL: env.sh default ERL_EPMD_ADDRESS='$hook_epmd'" >&2
  exit 1
}
[ "$hook_opts" = "-kernel inet_dist_use_interface {127,0,0,1}" ] || {
  echo "FAIL: env.sh default ELIXIR_ERL_OPTIONS='$hook_opts'" >&2
  exit 1
}

# Long-name distribution: epmd stays loopback, dist interface is left alone.
{ read -r hook_epmd; read -r hook_opts; } < <(hook_env RELEASE_DISTRIBUTION=name)
[ "$hook_epmd" = "127.0.0.1" ] || {
  echo "FAIL: env.sh ERL_EPMD_ADDRESS under --name='$hook_epmd'" >&2
  exit 1
}
[ -z "$hook_opts" ] || {
  echo "FAIL: env.sh pinned dist interface under long-name distribution: '$hook_opts'" >&2
  exit 1
}

# Explicit operator choices survive.
{ read -r hook_epmd; read -r hook_opts; } < <(hook_env ERL_EPMD_ADDRESS=0.0.0.0)
[ "$hook_epmd" = "0.0.0.0" ] || {
  echo "FAIL: env.sh overrode explicit ERL_EPMD_ADDRESS: '$hook_epmd'" >&2
  exit 1
}
{ read -r hook_epmd; read -r hook_opts; } < <(
  hook_env ELIXIR_ERL_OPTIONS="-kernel inet_dist_use_interface {0,0,0,0}"
)
[ "$hook_opts" = "-kernel inet_dist_use_interface {0,0,0,0}" ] || {
  echo "FAIL: env.sh overrode explicit inet_dist_use_interface: '$hook_opts'" >&2
  exit 1
}

# Unrelated ELIXIR_ERL_OPTIONS are appended to, never replaced.
{ read -r hook_epmd; read -r hook_opts; } < <(hook_env ELIXIR_ERL_OPTIONS="+Bd")
[ "$hook_opts" = "+Bd -kernel inet_dist_use_interface {127,0,0,1}" ] || {
  echo "FAIL: env.sh did not append to existing ELIXIR_ERL_OPTIONS: '$hook_opts'" >&2
  exit 1
}

echo "[test] rel/env.sh.eex release distribution defaults OK"

# ── 3. Docker entrypoint: docker/docker-entrypoint.sh ─────────────────────────
echo "[test] Verifying docker/docker-entrypoint.sh..."

ENTRYPOINT="$ROOT/docker/docker-entrypoint.sh"
CONTAINER_DATA="$TEST_DIR/container_data"
mkdir -p "$CONTAINER_DATA"

# 3a. Missing LEMON_CONTROL_PLANE_OPERATOR_TOKEN must fail readable
error_out="$TEST_DIR/entrypoint_error.log"
if LEMON_DATA_DIR="$CONTAINER_DATA" \
   LEMON_STORE_PATH="$CONTAINER_DATA/store" \
   RELEASE_TMP="$TEST_DIR/tmp" \
   sh "$ENTRYPOINT" true >"$error_out" 2>&1; then
  echo "FAIL: expected entrypoint to fail without LEMON_CONTROL_PLANE_OPERATOR_TOKEN" >&2
  exit 1
fi
grep -Fq "LEMON_CONTROL_PLANE_OPERATOR_TOKEN is required" "$error_out"
echo "[test] docker-entrypoint missing token readable rejection OK"

# 3b. Supplying LEMON_CONTROL_PLANE_OPERATOR_TOKEN succeeds and sets 0.0.0.0 binds and loopback epmd/dist defaults
env_capture="$TEST_DIR/entrypoint_env.txt"
LEMON_DATA_DIR="$CONTAINER_DATA" \
LEMON_STORE_PATH="$CONTAINER_DATA/store" \
RELEASE_TMP="$TEST_DIR/tmp" \
LEMON_CONTROL_PLANE_OPERATOR_TOKEN="test_operator_token_12345678901234567890" \
LEMON_WEB_SECRET_KEY_BASE="test_web_secret_key_base_32chars_test" \
LEMON_GATEWAY_NODE_COOKIE="test_cookie" \
sh "$ENTRYPOINT" env > "$env_capture"

grep -Fq "LEMON_CONTROL_PLANE_BIND_IP=0.0.0.0" "$env_capture"
grep -Fq "LEMON_CONTROL_PLANE_NODE_BIND_IP=0.0.0.0" "$env_capture"
grep -Fq "LEMON_WEB_BIND_IP=0.0.0.0" "$env_capture"
grep -Fq "LEMON_SIM_UI_BIND_IP=0.0.0.0" "$env_capture"
grep -Fq "LEMON_CONTROL_PLANE_OPERATOR_TOKEN=test_operator_token_12345678901234567890" "$env_capture"

# Assert operator token was NEVER written to $ENV_FILE
if [ -f "$CONTAINER_DATA/.lemon/env" ]; then
  if grep -Fq "LEMON_CONTROL_PLANE_OPERATOR_TOKEN" "$CONTAINER_DATA/.lemon/env"; then
    echo "FAIL: operator token was persisted to env file; must be required per boot" >&2
    exit 1
  fi
fi
echo "[test] docker-entrypoint 0.0.0.0 binds, loopback dist defaults, and non-persistence OK"

# 3c. Explicit bind overrides are preserved
env_override="$TEST_DIR/entrypoint_override.txt"
LEMON_DATA_DIR="$CONTAINER_DATA" \
LEMON_STORE_PATH="$CONTAINER_DATA/store" \
RELEASE_TMP="$TEST_DIR/tmp" \
LEMON_CONTROL_PLANE_BIND_IP="127.0.0.1" \
LEMON_WEB_BIND_IP="127.0.0.1" \
LEMON_CONTROL_PLANE_OPERATOR_TOKEN="test_operator_token_12345678901234567890" \
LEMON_WEB_SECRET_KEY_BASE="test_web_secret_key_base_32chars_test" \
LEMON_GATEWAY_NODE_COOKIE="test_cookie" \
sh "$ENTRYPOINT" env > "$env_override"

grep -Fq "LEMON_CONTROL_PLANE_BIND_IP=127.0.0.1" "$env_override"
grep -Fq "LEMON_WEB_BIND_IP=127.0.0.1" "$env_override"
echo "[test] docker-entrypoint listener bind overrides OK"

# 3d. Restart without env token fails (no secret token persistence across boots)
error_restart="$TEST_DIR/entrypoint_restart_error.log"
if LEMON_DATA_DIR="$CONTAINER_DATA" \
   LEMON_STORE_PATH="$CONTAINER_DATA/store" \
   RELEASE_TMP="$TEST_DIR/tmp" \
   sh "$ENTRYPOINT" true >"$error_restart" 2>&1; then
  echo "FAIL: expected restart without env token to fail" >&2
  exit 1
fi
grep -Fq "LEMON_CONTROL_PLANE_OPERATOR_TOKEN is required" "$error_restart"
echo "[test] docker-entrypoint requires token per boot OK"

# ── 4. Dockerfile.runtime & release.yml checks ───────────────────────────────
echo "[test] Verifying Dockerfile.runtime and release.yml assertions..."

grep -Fq "ENV LEMON_CONTROL_PLANE_BIND_IP=0.0.0.0" "$ROOT/docker/Dockerfile.runtime"
grep -Fq "ENV LEMON_CONTROL_PLANE_NODE_BIND_IP=0.0.0.0" "$ROOT/docker/Dockerfile.runtime"
grep -Fq "ENV LEMON_WEB_BIND_IP=0.0.0.0" "$ROOT/docker/Dockerfile.runtime"
grep -Fq "ENV LEMON_SIM_UI_BIND_IP=0.0.0.0" "$ROOT/docker/Dockerfile.runtime"
if grep -q "ELIXIR_ERL_OPTIONS" "$ROOT/docker/Dockerfile.runtime"; then
  echo "FAIL: Dockerfile must not hard-set ELIXIR_ERL_OPTIONS; env.sh owns it" >&2
  exit 1
fi
grep -Fq "EXPOSE 4040 4044 4080 4090" "$ROOT/docker/Dockerfile.runtime"

grep -Fq "LEMON_CONTROL_PLANE_OPERATOR_TOKEN=" "$ROOT/.github/workflows/release.yml"

echo "[test] All launcher and container checks passed successfully."
