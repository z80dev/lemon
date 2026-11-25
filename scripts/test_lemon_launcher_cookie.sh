#!/usr/bin/env bash
# Real OTP nodes through the source command builder and hardened release scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-cookie.XXXXXX")"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT
export HOME="$TEST_DIR/home" ERL_FLAGS='+S 2:2 +A 1' ERL_EPMD_ADDRESS=127.0.0.1
unset MIX_ENV MIX_BUILD_PATH MIX_DEPS_PATH RELEASE_COOKIE LEMON_GATEWAY_NODE_COOKIE LEMON_GATEWAY_COOKIE ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_ZFLAGS
mkdir -p "$HOME" "$TEST_DIR/fixture/lib" "$TEST_DIR/fixture/rel" \
  "$TEST_DIR/fixture/apps/lemon_cli/lib/lemon_cli"
FIXTURE="$TEST_DIR/fixture"
ln -s "$ROOT/apps/lemon_cli/lib/lemon_cli/distribution.ex" "$FIXTURE/lib/distribution.ex"
export ERL_CRASH_DUMP="$TEST_DIR/erl_crash.dump"
ln -s "$ROOT/apps/lemon_cli/lib/lemon_cli/distribution.ex" "$FIXTURE/apps/lemon_cli/lib/lemon_cli/distribution.ex"
ln -s "$ROOT/rel/env.sh.eex" "$FIXTURE/rel/env.sh.eex"
export LEMON_COOKIE_RELEASE_STEP="$ROOT/rel/distribution.exs"
cat > "$FIXTURE/mix.exs" <<'ELIXIR'
Code.require_file(System.fetch_env!("LEMON_COOKIE_RELEASE_STEP"))
defmodule CookieFixture.MixProject do
  use Mix.Project
  def project do
    [app: :cookie_fixture, version: "0.1.0",
     releases: [cookie_fixture: [include_erts: false, include_executables_for: [:unix],
       steps: [:assemble, &Lemon.DistributionRelease.secure/1]]]]
  end
  def application, do: [mod: {LemonCore.Runtime.Boot, []}]
end
ELIXIR
cat > "$FIXTURE/lib/boot.ex" <<'ELIXIR'
defmodule LemonCore.Runtime.Boot do
  use Application
  def start(_type, _args) do
    start!(:runtime_full)
    Supervisor.start_link([], strategy: :one_for_one)
  end
  def start!(:runtime_full) do
    true = Node.alive?()
    true = Node.get_cookie() == String.to_atom(File.read!(Path.join(System.user_home!(), ".lemon/cookie")) |> String.trim())
    target = System.get_env("LEMON_COOKIE_TEST_TARGET")
    if target do
      :pong = Node.ping(String.to_atom(target))
      true = :rpc.call(String.to_atom(target), Node, :alive?, [])
    end
    false = File.exists?(Path.join(System.user_home!(), ".erlang.cookie"))
    kernel_servers!()
    File.write!(System.fetch_env!("LEMON_COOKIE_TEST_READY"), System.pid())
  end
  # start_distribution false must not drop the rpc and global kernel servers
  # that native session ownership (:global) relies on.
  def kernel_servers! do
    true = Enum.all?([:rex, :global_name_server, :global_group], &is_pid(Process.whereis(&1)))
    name = {:cookie_fixture, node(), System.pid()}
    :yes = :global.register_name(name, spawn(fn -> Process.sleep(:infinity) end))
    true = is_pid(:global.whereis_name(name))
  end
end
ELIXIR
(cd "$FIXTURE" && mix release --overwrite) > "$TEST_DIR/build.log" 2>&1 || { cat "$TEST_DIR/build.log"; exit 1; }

load_function() {
  eval "$(awk -v name="$2" '$0 == name "() {" || $0 == name "() (" {copy=1} copy {print} copy && /^[})]$/ {exit}' "$1")"
}
start_source() (
  # Only service orchestration is stubbed. The real start_runtime builds and
  # execs its unmodified elixir/Mix argv; the fixture replaces the app payload.
  load_function "$ROOT/bin/lemon" start_runtime
  control_plane_healthy() { return 1; }
  managed_runtime_pidfile() { return 1; }
  control_port_in_use() { return 1; }
  restore_in_progress() { return 1; }
  for fn in acquire_start_lock record_runtime_paths ensure_managed_token load_secrets_master_key compile_source info release_start_lock record_runtime_pid; do
    eval "$fn() { :; }"
  done
  LEMON_ROOT="$FIXTURE" LEMON_HOME_DIR="$HOME/.lemon"
  PIDFILE="$TEST_DIR/$1.pid" ROOTFILE="$TEST_DIR/$1.root"
  NODE_COOKIE='' NODE_MODE=sname NODE_NAME="$1@localhost" DISTRIBUTED=1
  PORT=4040 WEB_PORT=4080 DEBUG='' LAUNCH_CWD="$FIXTURE"
  export LEMON_COOKIE_TEST_READY="$TEST_DIR/$1.ready"
  start_runtime foreground
)
wait_ready() {
  local attempt
  for ((attempt=0; attempt<200; attempt++)); do
    [ ! -s "$1" ] || return 0
    kill -0 "$2" 2>/dev/null || break
    sleep 0.1
  done
  cat "$TEST_DIR"/*.log >&2
  echo "node did not become ready: $1" >&2
  exit 1
}
check_argv() {
  PID_UNDER_TEST="$1" COOKIE_EXPECTED="$(cat "$HOME/.lemon/cookie")" python3 - <<'PY'
import ctypes
import os
import struct
import subprocess
import sys

pid = int(os.environ["PID_UNDER_TEST"])
secret = os.environ["COOKIE_EXPECTED"].encode()
ps = subprocess.check_output(["ps", "-ww", "-o", "args=", "-p", str(pid)])
assert secret not in ps, "cookie exposed by ps"
assert b"-setcookie" not in ps and b"--cookie" not in ps, "cookie argument remains"
if sys.platform == "darwin":
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(os.sysconf("SC_ARG_MAX"))
    buf = ctypes.create_string_buffer(size.value)
    assert libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) == 0, ctypes.get_errno()
    raw = buf.raw[:size.value]
    argc = struct.unpack_from("i", raw)[0]
    pos = raw.index(b"\0", struct.calcsize("i")) + 1  # executable path
    while raw[pos] == 0:
        pos += 1
    argv = raw[pos:].split(b"\0", argc)[:argc]  # exclude the environment
    assert len(argv) == argc
    native = b"\0".join(argv)
    source = "KERN_PROCARGS2"
elif sys.platform.startswith("linux"):
    with open(f"/proc/{pid}/cmdline", "rb") as stream:
        native = stream.read()
    source = "/proc/pid/cmdline"
else:
    raise AssertionError("native argv regression requires Linux or macOS")
assert secret not in native, f"cookie exposed by {source}"
assert b"-setcookie" not in native and b"--cookie" not in native
print(f"PID {pid}: ps -ww -o args= and {source}: cookie absent")
print(ps.decode().strip())
PY
}

first="cookie_source_$$"
start_source "$first" > "$TEST_DIR/source.log" 2>&1 &
PIDS+=("$!")
wait_ready "$TEST_DIR/$first.ready" "${PIDS[0]}"
check_argv "$(cat "$TEST_DIR/$first.ready")"
second="cookie_peer_$$"
LEMON_COOKIE_TEST_TARGET="$first@localhost" start_source "$second" > "$TEST_DIR/peer.log" 2>&1 &
PIDS+=("$!")
wait_ready "$TEST_DIR/$second.ready" "${PIDS[1]}"
check_argv "$(cat "$TEST_DIR/$second.ready")"
printf '%s\n' 'two source nodes connected and completed authenticated RPC'

RELEASE_BIN="$FIXTURE/_build/dev/rel/cookie_fixture/bin/cookie_fixture"
export RELEASE_NODE="cookie_release_$$@localhost"
LEMON_COOKIE_TEST_READY="$TEST_DIR/release.ready" LEMON_COOKIE_TEST_TARGET="$first@localhost" \
  "$RELEASE_BIN" start > "$TEST_DIR/release.log" 2>&1 &
PIDS+=("$!")
wait_ready "$TEST_DIR/release.ready" "${PIDS[2]}"
check_argv "$(cat "$TEST_DIR/release.ready")"
"$RELEASE_BIN" rpc \
  'true = Node.alive?(); File.write!(Path.join(System.user_home!(), "rpc.ready"), System.pid()); Process.sleep(:infinity)' \
  > "$TEST_DIR/rpc.log" 2>&1 &
# rpc executes the expression on the server. Inspect the blocked hidden client
# itself via its exec-preserved PID, not the server PID written by the RPC.
PIDS+=("$!")
wait_ready "$HOME/rpc.ready" "${PIDS[3]}"
check_argv "${PIDS[3]}"
LEMON_COOKIE_TEST_READY="$TEST_DIR/eval.ready" "$RELEASE_BIN" eval \
  'false = Node.alive?(); LemonCore.Runtime.Boot.kernel_servers!(); File.write!(System.fetch_env!("LEMON_COOKIE_TEST_READY"), System.pid()); Process.sleep(:infinity)' \
  > "$TEST_DIR/eval.log" 2>&1 &
PIDS+=("$!")
wait_ready "$TEST_DIR/eval.ready" "${PIDS[4]}"
check_argv "$(cat "$TEST_DIR/eval.ready")"

mkfifo "$TEST_DIR/remote.stdin"
exec 9<>"$TEST_DIR/remote.stdin"
"$RELEASE_BIN" remote <"$TEST_DIR/remote.stdin" >"$TEST_DIR/remote.log" 2>&1 &
PIDS+=("$!")
printf '%s\n' 'File.write!(Path.join(System.user_home!(), "remote.ready"), "ready")' >&9
wait_ready "$HOME/remote.ready" "${PIDS[5]}"
check_argv "${PIDS[5]}"
exec 9>&-

# The documented source remsh uses the same deferred user driver. Plain iex
# would try to connect during kernel boot, before a -s initializer can run.
mkfifo "$TEST_DIR/source-remote.stdin"
exec 9<>"$TEST_DIR/source-remote.stdin"
RELEASE_COOKIE="$(cat "$HOME/.lemon/cookie")" elixir --no-halt \
  --erl "-user Elixir.LemonCli.Distribution -kernel start_distribution false -nocookie -pa $FIXTURE/_build/dev/lib/cookie_fixture/ebin -s Elixir.LemonCli.Distribution boot" \
  +iex --sname "cookie_console_$$@localhost" --remsh "$first@localhost" \
  <"$TEST_DIR/source-remote.stdin" >"$TEST_DIR/source-remote.log" 2>&1 &
PIDS+=("$!")
printf '%s\n' 'File.write!(Path.join(System.user_home!(), "source-remote.ready"), "ready")' >&9
wait_ready "$HOME/source-remote.ready" "${PIDS[6]}"
check_argv "${PIDS[6]}"
exec 9>&-

RELEASE_COOKIE="$(cat "$HOME/.lemon/cookie")" elixir --erl "-dist_listen false -nocookie" \
  --sname "cookie_rpc_$$@localhost" \
  -e 'Node.set_cookie(String.to_atom(System.fetch_env!("RELEASE_COOKIE")))' \
  --rpc-eval "$first@localhost" \
  'File.write!(Path.join(System.user_home!(), "source-rpc.ready"), "ready"); Process.sleep(:infinity)' \
  >"$TEST_DIR/source-rpc.log" 2>&1 &
PIDS+=("$!")
wait_ready "$HOME/source-rpc.ready" "${PIDS[7]}"
check_argv "${PIDS[7]}"

# Pin the OTP-private contract and its fail-closed guard, independently of Mix.
RELEASE_COOKIE="$(cat "$HOME/.lemon/cookie")" elixir --erl '-kernel start_distribution false -nocookie' \
  -r "$ROOT/apps/lemon_cli/lib/lemon_cli/distribution.ex" -e '
  options = %{name: :cookie_contract, name_domain: :shortnames, clean_halt: false, supervisor: :net_sup_dynamic}
  {_flags, children} = LemonCli.Distribution.distribution_spec!(options)
  [:net_kernel, :auth | _] = children |> Enum.reverse() |> Enum.map(& &1.id)
  :ok = Application.put_env(:kernel, :start_distribution, true)
  try do
    LemonCli.Distribution.distribution_spec!(options)
    raise "unsafe distribution configuration was accepted"
  rescue
    e in RuntimeError -> true = String.starts_with?(e.message, "Secure distribution boot refused on OTP ")
  end'
[ ! -e "$HOME/.erlang.cookie" ]
python3 - "$HOME/.lemon/cookie" <<'PY'
import os
import stat
import sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
printf '%s\n' 'source/release cookie argv and OTP startup-contract regressions passed'
