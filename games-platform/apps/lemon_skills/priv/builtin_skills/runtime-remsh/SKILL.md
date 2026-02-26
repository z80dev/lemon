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

Attach from another terminal (short-name default):

```bash
iex --sname lemon_attach --cookie lemon_gateway_dev_cookie --remsh "lemon_gateway@$(hostname -s)"
```

If gateway was started with explicit settings, use those exact values:

```bash
./bin/lemon-gateway --sname lemon_gateway --cookie "change-me"
iex --sname lemon_attach --cookie "change-me" --remsh "lemon_gateway@$(hostname -s)"
```

For long-name mode:

```bash
./bin/lemon-gateway --name lemon_gateway@my-host.example.com --cookie "change-me"
iex --name lemon_attach@my-host.example.com --cookie "change-me" --remsh lemon_gateway@my-host.example.com
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
elixir --sname lemon_probe --cookie lemon_gateway_dev_cookie --rpc-eval "lemon_gateway@$(hostname -s)" "IO.inspect(LemonGateway.Config.get(:default_engine))"
```

Long-name one-off:

```bash
elixir --name lemon_probe@my-host.example.com --cookie "change-me" --rpc-eval "lemon_gateway@my-host.example.com" "IO.puts(node())"
```

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
