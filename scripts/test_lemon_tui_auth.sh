#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-tui-auth-test.XXXXXX")"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cleanup() {
  if [[ -f "$TEST_DIR/runtime.pid" ]]; then
    runtime_pid="$(<"$TEST_DIR/runtime.pid")"
    if [[ "$runtime_pid" =~ ^[0-9]+$ && "$runtime_pid" -gt 1 ]]; then
      kill -KILL "$runtime_pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
[[ -f "$LEMON_TUI_TEST_HEALTH" ]]
EOF

cat > "$FAKE_BIN/bun" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "install" ]]; then
  printf '%s' "${LEMON_CONTROL_PLANE_OPERATOR_TOKEN:-}" > "$LEMON_TUI_TEST_INSTALL_TOKEN"
  exit 0
fi

printf '%s' "${LEMON_CONTROL_PLANE_OPERATOR_TOKEN:-}" > "$LEMON_TUI_TEST_CLIENT_TOKEN"
printf '%s\n' "$@" > "$LEMON_TUI_TEST_CLIENT_ARGS"
EOF

cat > "$TEST_DIR/runtime-launcher" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${LEMON_CONTROL_PLANE_OPERATOR_TOKEN:-}" > "$LEMON_TUI_TEST_RUNTIME_TOKEN"
printf '%s\n' "$@" > "$LEMON_TUI_TEST_RUNTIME_ARGS"

if [[ -n "${LEMON_RUNTIME_PID_FILE:-}" ]]; then
  sleep 300 &
  runtime_pid=$!
  printf '%s\n' "$runtime_pid" > "$LEMON_RUNTIME_PID_FILE"
  printf '%s\n' "$runtime_pid" > "$LEMON_TUI_TEST_RUNTIME_PID"
fi

touch "$LEMON_TUI_TEST_HEALTH"
EOF

chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/bun" "$TEST_DIR/runtime-launcher"

export PATH="$FAKE_BIN:$PATH"
export LEMON_TUI_RUNTIME_LAUNCHER="$TEST_DIR/runtime-launcher"
export LEMON_TUI_TEST_HEALTH="$TEST_DIR/health"
export LEMON_TUI_TEST_INSTALL_TOKEN="$TEST_DIR/install-token"
export LEMON_TUI_TEST_CLIENT_TOKEN="$TEST_DIR/client-token"
export LEMON_TUI_TEST_CLIENT_ARGS="$TEST_DIR/client-args"
export LEMON_TUI_TEST_RUNTIME_TOKEN="$TEST_DIR/runtime-token"
export LEMON_TUI_TEST_RUNTIME_ARGS="$TEST_DIR/runtime-args"
export LEMON_TUI_TEST_RUNTIME_PID="$TEST_DIR/runtime.pid"

unset LEMON_CONTROL_PLANE_OPERATOR_TOKEN
unset LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK
unset LEMON_RUNTIME_PID_FILE
unset LEMON_WS_TOKEN

bootstrap_output="$TEST_DIR/bootstrap-output"
"$ROOT/bin/lemon-tui" --test-argument > "$bootstrap_output" 2>&1

runtime_token="$(<"$LEMON_TUI_TEST_RUNTIME_TOKEN")"
client_token="$(<"$LEMON_TUI_TEST_CLIENT_TOKEN")"
runtime_pid="$(<"$LEMON_TUI_TEST_RUNTIME_PID")"

[[ "$runtime_token" =~ ^[0-9a-fA-F]{64}$ ]]
[[ "$runtime_token" == "$client_token" ]]
[[ ! -s "$LEMON_TUI_TEST_INSTALL_TOKEN" ]]
grep -qx -- '--daemon' "$LEMON_TUI_TEST_RUNTIME_ARGS"
grep -qx -- '--test-argument' "$LEMON_TUI_TEST_CLIENT_ARGS"
! grep -Fq -- "$runtime_token" "$LEMON_TUI_TEST_CLIENT_ARGS"
! grep -Fq -- "$runtime_token" "$bootstrap_output"

for _ in $(seq 1 50); do
  kill -0 "$runtime_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$runtime_pid" 2>/dev/null; then
  echo "launcher-owned runtime was not stopped" >&2
  exit 1
fi

touch "$LEMON_TUI_TEST_HEALTH"
rm -f "$LEMON_TUI_TEST_CLIENT_TOKEN"

existing_output="$TEST_DIR/existing-output"
if "$ROOT/bin/lemon-tui" > "$existing_output" 2>&1; then
  echo "tokenless attachment to an existing runtime unexpectedly succeeded" >&2
  exit 1
fi

grep -Fq 'Set LEMON_CONTROL_PLANE_OPERATOR_TOKEN' "$existing_output"
[[ ! -e "$LEMON_TUI_TEST_CLIENT_TOKEN" ]]

rm -f "$LEMON_TUI_TEST_HEALTH"
stable_token='test-stable-operator-token'
export LEMON_CONTROL_PLANE_OPERATOR_TOKEN="$stable_token"
if ! "$ROOT/bin/lemon-tui" > "$TEST_DIR/stable-output" 2>&1; then
  cat "$TEST_DIR/stable-output" >&2
  exit 1
fi

[[ "$(<"$LEMON_TUI_TEST_RUNTIME_TOKEN")" == "$stable_token" ]]
[[ "$(<"$LEMON_TUI_TEST_CLIENT_TOKEN")" == "$stable_token" ]]
! grep -Fq -- "$stable_token" "$TEST_DIR/stable-output"

echo "lemon-tui auth bootstrap tests passed"
