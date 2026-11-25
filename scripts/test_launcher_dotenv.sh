#!/usr/bin/env bash
# Source launchers must not hand a cloned repository's .env to the runtime:
# environment variables override every config file. Each launcher is run from a
# repo directory with a fake `mix`/`elixir` that records the LEMON_DOTENV_DIR
# the runtime would load.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-launcher-dotenv-test.XXXXXX")"
FAKE_BIN="$TEST_DIR/bin"
RECORD="$TEST_DIR/dotenv-dir"
REPO="$TEST_DIR/repo"
FAKE_HOME="$TEST_DIR/home"

cleanup() {
  if [[ "$TEST_DIR" == "${TMPDIR:-/tmp}"/lemon-launcher-dotenv-test.* ]]; then
    rm -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$REPO" "$FAKE_HOME/.lemon"
printf 'LEMON_EXTENSION_PATHS=%s/evil\n' "$REPO" > "$REPO/.env"

for tool in mix elixir; do
  cat > "$FAKE_BIN/$tool" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" run "*) printf '%s' "\${LEMON_DOTENV_DIR:-}" > "$RECORD" ;;
esac
exit 0
EOF
  chmod +x "$FAKE_BIN/$tool"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE_BIN/security"
chmod +x "$FAKE_BIN/security"

# Free ports keep the launcher's health probe from reusing a developer runtime.
free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
CONTROL_PORT="$(free_port)"
WEB_PORT="$(free_port)"

# run_launcher <dotenv dir or ""> <launcher> [args...]
run_launcher() {
  local dotenv=() launcher="$2"
  [ -z "$1" ] || dotenv=(LEMON_DOTENV_DIR="$1")
  shift 2
  rm -f "$RECORD"
  (
    cd "$REPO"
    env -u LEMON_DOTENV_DIR -u LEMON_STORE_PATH -u LEMON_RUNTIME_PID_FILE \
      -u LEMON_RUNTIME_LOG_FILE HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" \
      LEMON_CONTROL_PLANE_PORT="$CONTROL_PORT" LEMON_WEB_PORT="$WEB_PORT" \
      LEMON_SECRETS_MASTER_KEY=test ${dotenv[@]+"${dotenv[@]}"} "$ROOT/bin/$launcher" "$@" --no-distribution >/dev/null
  )
  cat "$RECORD"
}

expect() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $name loaded .env from '$got', expected '$want'" >&2
    exit 1
  fi
  echo "ok: $name"
}

# lemon-gateway is `lemon start` under another node name; run both for real.
for launcher in lemon-gateway "lemon start"; do
  # shellcheck disable=SC2086 # "lemon start" is launcher plus command
  expect "$launcher default" "$(run_launcher "" $launcher)" "$FAKE_HOME/.lemon"
  # shellcheck disable=SC2086
  expect "$launcher explicit" \
    "$(run_launcher "$TEST_DIR/operator" $launcher)" "$TEST_DIR/operator"
done

if grep -n 'LEMON_DOTENV_DIR.*LAUNCH_CWD\|DOTENV_DIR.*LAUNCH_CWD' "$ROOT"/bin/lemon*; then
  echo "FAIL: a launcher still loads .env from the launch directory" >&2
  exit 1
fi
echo "ok: bin/lemon"
