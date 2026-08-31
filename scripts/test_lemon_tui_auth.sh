#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-tui-auth-test.XXXXXX")"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cleanup() {
  local pid_file
  local runtime_pid

  for pid_file in "$TEST_DIR/runtime.pid" "$TEST_DIR/source-runtime.pid" "$TEST_DIR/package-runtime.pid"; do
    if [[ -f "$pid_file" ]]; then
      runtime_pid="$(<"$pid_file")"
      if [[ "$runtime_pid" =~ ^[0-9]+$ && "$runtime_pid" -gt 1 ]]; then
        kill -KILL "$runtime_pid" 2>/dev/null || true
      fi
    fi
  done

  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$LEMON_TUI_TEST_HEALTH" ]]; then
  printf '{"ok":true}\n'
  exit 0
fi
exit 1
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

cat > "$FAKE_BIN/mix" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "--no-halt" ]]; then
    printf '%s' "${LEMON_CONTROL_PLANE_OPERATOR_TOKEN:-}" > "$LEMON_TUI_TEST_SOURCE_RUNTIME_TOKEN"
    sleep 300
    exit 0
  fi
done
EOF

cat > "$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/bun" "$FAKE_BIN/mix" "$FAKE_BIN/security" "$TEST_DIR/runtime-launcher"

export PATH="$FAKE_BIN:$PATH"
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"
export LEMON_TUI_RUNTIME_LAUNCHER="$TEST_DIR/runtime-launcher"
export LEMON_TUI_TEST_HEALTH="$TEST_DIR/health"
export LEMON_TUI_TEST_INSTALL_TOKEN="$TEST_DIR/install-token"
export LEMON_TUI_TEST_CLIENT_TOKEN="$TEST_DIR/client-token"
export LEMON_TUI_TEST_CLIENT_ARGS="$TEST_DIR/client-args"
export LEMON_TUI_TEST_RUNTIME_TOKEN="$TEST_DIR/runtime-token"
export LEMON_TUI_TEST_RUNTIME_ARGS="$TEST_DIR/runtime-args"
export LEMON_TUI_TEST_RUNTIME_PID="$TEST_DIR/runtime.pid"
export LEMON_TUI_TEST_SOURCE_RUNTIME_TOKEN="$TEST_DIR/source-runtime-token"

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

grep -Fq 'No credential is available' "$existing_output"
[[ ! -e "$LEMON_TUI_TEST_CLIENT_TOKEN" ]]

managed_port=45555
managed_pid_file="$TEST_DIR/source-runtime.pid"
rm -f "$LEMON_TUI_TEST_HEALTH" "$LEMON_TUI_TEST_CLIENT_TOKEN"
export LEMON_RUNTIME_PID_FILE="$managed_pid_file"

if ! "$ROOT/bin/lemon" --daemon --no-distribution --port "$managed_port" > "$TEST_DIR/source-daemon-output" 2>&1; then
  cat "$TEST_DIR/source-daemon-output" >&2
  exit 1
fi

managed_token_file="$HOME/.lemon/run/control-plane-${managed_port}.token"
managed_token="$(<"$managed_token_file")"
managed_mode="$(stat -f '%Lp' "$managed_token_file" 2>/dev/null || stat -c '%a' "$managed_token_file")"
[[ "$managed_token" =~ ^[0-9a-fA-F]{64}$ ]]
[[ "$managed_mode" == "600" ]]
[[ "$(<"$LEMON_TUI_TEST_SOURCE_RUNTIME_TOKEN")" == "$managed_token" ]]

touch "$LEMON_TUI_TEST_HEALTH"
export LEMON_CONTROL_PLANE_PORT="$managed_port"
if ! "$ROOT/bin/lemon-tui" > "$TEST_DIR/managed-attach-output" 2>&1; then
  cat "$TEST_DIR/managed-attach-output" >&2
  exit 1
fi

[[ "$(<"$LEMON_TUI_TEST_CLIENT_TOKEN")" == "$managed_token" ]]
! grep -Fq -- "$managed_token" "$TEST_DIR/managed-attach-output"

managed_runtime_pid="$(<"$managed_pid_file")"
kill -TERM "$managed_runtime_pid" 2>/dev/null || true
unset LEMON_CONTROL_PLANE_PORT
unset LEMON_RUNTIME_PID_FILE

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

stable_runtime_pid="$(<"$LEMON_TUI_TEST_RUNTIME_PID")"
for _ in $(seq 1 50); do
  kill -0 "$stable_runtime_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$stable_runtime_pid" 2>/dev/null; then
  echo "preconfigured-token runtime was not stopped" >&2
  exit 1
fi

unset LEMON_CONTROL_PLANE_OPERATOR_TOKEN
release_root="$TEST_DIR/release"
package_home="$TEST_DIR/package-home"
package_health="$TEST_DIR/package-health"
package_runtime_token="$TEST_DIR/package-runtime-token"
package_client_token="$TEST_DIR/package-client-token"
mkdir -p "$release_root/bin" "$release_root/tui/bin" "$package_home"
cp "$ROOT/rel/overlays/bin/lemon" "$release_root/bin/lemon"

cat > "$release_root/bin/lemon_runtime_min" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  daemon)
    printf '%s' "${LEMON_CONTROL_PLANE_OPERATOR_TOKEN:-}" > "$LEMON_TUI_TEST_PACKAGE_RUNTIME_TOKEN"
    sleep 300 &
    printf '%s\n' "$!" > "$LEMON_TUI_TEST_PACKAGE_RUNTIME_PID"
    touch "$LEMON_TUI_TEST_HEALTH"
    ;;
  pid)
    cat "$LEMON_TUI_TEST_PACKAGE_RUNTIME_PID"
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat > "$release_root/tui/bin/lemon-tui" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${LEMON_CONTROL_PLANE_OPERATOR_TOKEN:-}" > "$LEMON_TUI_TEST_PACKAGE_CLIENT_TOKEN"
EOF

chmod +x "$release_root/bin/lemon" "$release_root/bin/lemon_runtime_min" "$release_root/tui/bin/lemon-tui"
export HOME="$package_home"
export LEMON_CONTROL_PLANE_PORT=46666
export LEMON_TUI_TEST_HEALTH="$package_health"
export LEMON_TUI_TEST_PACKAGE_RUNTIME_TOKEN="$package_runtime_token"
export LEMON_TUI_TEST_PACKAGE_RUNTIME_PID="$TEST_DIR/package-runtime.pid"
export LEMON_TUI_TEST_PACKAGE_CLIENT_TOKEN="$package_client_token"

if ! "$release_root/bin/lemon" tui > "$TEST_DIR/package-first-output" 2>&1; then
  cat "$TEST_DIR/package-first-output" >&2
  exit 1
fi

package_token_file="$package_home/.lemon/run/control-plane-46666.token"
package_token="$(<"$package_token_file")"
package_mode="$(stat -f '%Lp' "$package_token_file" 2>/dev/null || stat -c '%a' "$package_token_file")"
[[ "$package_token" =~ ^[0-9a-fA-F]{64}$ ]]
[[ "$package_mode" == "600" ]]
[[ "$(<"$package_runtime_token")" == "$package_token" ]]
[[ "$(<"$package_client_token")" == "$package_token" ]]
! grep -Fq -- "$package_token" "$TEST_DIR/package-first-output"

rm -f "$package_client_token"
if ! "$release_root/bin/lemon" tui > "$TEST_DIR/package-attach-output" 2>&1; then
  cat "$TEST_DIR/package-attach-output" >&2
  exit 1
fi

[[ "$(<"$package_client_token")" == "$package_token" ]]
! grep -Fq -- "$package_token" "$TEST_DIR/package-attach-output"

kill -TERM "$(<"$TEST_DIR/package-runtime.pid")" 2>/dev/null || true

echo "lemon-tui auth bootstrap tests passed"
