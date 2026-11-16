---
name: runtime-remsh
description: Connect to a running Lemon or lemon-gateway BEAM node, run recompile() for hot code reload, and execute Elixir code in that live runtime via IEx remsh or rpc-eval.
metadata: { "lemon": { "requires": { "bins": ["elixir", "iex"] } } }
---

# runtime-remsh

Use this skill when the user asks to connect to a running Lemon instance, recompile changed Elixir code without restarting, or run Elixir inside the live runtime.

## Trigger

Use this skill for requests like:

- "connect to the running gateway"
- "attach to lemon and run recompile()"
- "execute this Elixir in the live runtime"
- "run rpc-eval against the node"

## Preconditions

- The target process must be started as a distributed node (`--sname` or `--name`) with a cookie.
- The attaching shell must use the same naming mode and same cookie.
- For `./bin/lemon-gateway`, do not use `--no-distribution`.

## Quickstart (local gateway)

Start gateway (terminal 1):

```bash
./bin/lemon-gateway
```

Attach from another terminal, from the checkout root (short-name default):

```bash
export RELEASE_COOKIE="$(cat "$HOME/.lemon/cookie")"
LEMON_ATTACH_ERL="-user Elixir.LemonCli.Distribution -kernel start_distribution false -nocookie -pa $PWD/_build/dev/lib/lemon_cli/ebin -s Elixir.LemonCli.Distribution boot"
elixir --no-halt --erl "$LEMON_ATTACH_ERL" +iex \
  --sname lemon_attach --remsh "lemon_gateway@$(hostname -s)"
```

The gateway compiles the bootstrap module before launch. Its deferred IEx user
driver installs the cookie before opening distribution or connecting the shell.
Never pass a cookie as a command-line argument, in `ERL_FLAGS`, or in `vm.args`:
OTP expands those flags into process argv. If the gateway uses an explicit
environment cookie, securely supply the same `RELEASE_COOKIE` in the attaching
terminal instead of reading the per-install file.

For long-name mode:

```bash
./bin/lemon-gateway --name lemon_gateway@my-host.example.com
elixir --no-halt --erl "$LEMON_ATTACH_ERL" +iex \
  --name lemon_attach@my-host.example.com --remsh lemon_gateway@my-host.example.com
```

Tip: `./bin/lemon-gateway` prints the exact `Remote shell target` to use.

## Recompile changed code in the live runtime

Inside attached IEx:

```elixir
recompile()
```

Useful follow-up checks:

```elixir
node()
Application.started_applications() |> Enum.map(&elem(&1, 0))
```

If needed, force reload a module:

```elixir
r(LemonGateway.Run)
```

## Execute arbitrary Elixir code in the live runtime

Interactive (`--remsh`) examples:

```elixir
LemonGateway.Config.get()
LemonGateway.Config.get(:default_engine)
```

Non-interactive one-off (`--rpc-eval`) example:

```bash
elixir --erl "-dist_listen false -nocookie" --sname lemon_probe \
  -e 'Node.set_cookie(String.to_atom(System.fetch_env!("RELEASE_COOKIE")))' \
  --rpc-eval "lemon_gateway@$(hostname -s)" "IO.inspect(LemonGateway.Config.get(:default_engine))"
```

Long-name one-off:

```bash
elixir --erl "-dist_listen false -nocookie" --name lemon_probe@my-host.example.com \
  -e 'Node.set_cookie(String.to_atom(System.fetch_env!("RELEASE_COOKIE")))' \
  --rpc-eval "lemon_gateway@my-host.example.com" "IO.puts(node())"
```

These non-listening clients set the environment cookie before their first RPC;
`-nocookie` prevents reading or creating `~/.erlang.cookie`. Packaged installs
can use `lemon remote` and `lemon rpc EXPR` directly with the same guarded boot.

## Troubleshooting

- `nodedown` or timeout:
  - Ensure both sides use short names (`--sname`) or both use long names (`--name`).
  - Confirm the exact target node name from gateway startup logs.
- `Invalid challenge reply`:
  - Cookie mismatch. Use the same cookie on launcher and attach command.
- Attach works but app calls fail:
  - Target process may have exited after startup; check gateway logs.
- Verify registration with EPMD:

```bash
epmd -names
```

## Safety

- Default to read-only inspection unless the user asked to mutate state.
- Call out risky runtime actions before executing them (state mutation, process termination, file/network side effects).
- Prefer `--rpc-eval` for small one-off checks and `--remsh` for multi-step debugging.
