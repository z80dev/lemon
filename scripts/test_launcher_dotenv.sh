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

run_launcher() {
  local launcher="$1"
  shift
  rm -f "$RECORD"
  (
    cd "$REPO"
    env -u LEMON_DOTENV_DIR HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" \
      LEMON_SECRETS_MASTER_KEY=test "$@" "$ROOT/bin/$launcher" --no-distribution >/dev/null
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

for launcher in lemon-gateway lemon-control-plane; do
  expect "$launcher default" "$(run_launcher "$launcher")" "$FAKE_HOME/.lemon"
  expect "$launcher explicit" \
    "$(run_launcher "$launcher" LEMON_DOTENV_DIR="$TEST_DIR/operator")" "$TEST_DIR/operator"
done

# bin/lemon starts a supervised daemon, so check its single dotenv export.
# shellcheck disable=SC2016 # literal launcher text, not an expansion
grep -q 'export LEMON_DOTENV_DIR="${LEMON_DOTENV_DIR:-$LEMON_HOME_DIR}"' "$ROOT/bin/lemon" || {
  echo "FAIL: bin/lemon must default LEMON_DOTENV_DIR to the Lemon home" >&2
  exit 1
}
if grep -n 'LEMON_DOTENV_DIR.*LAUNCH_CWD\|DOTENV_DIR.*LAUNCH_CWD' "$ROOT"/bin/lemon*; then
  echo "FAIL: a launcher still loads .env from the launch directory" >&2
  exit 1
fi
echo "ok: bin/lemon"
