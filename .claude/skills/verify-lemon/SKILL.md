---
name: verify-lemon
description: "Verify lemon features against a running (or disposable) instance using the cheapest sufficient tier: DIRECT (attach/RPC + control-plane WS + bus observation, no Telegram), FAKE TELEGRAM (hermetic transport via LemonChannels.Telegram.FakeAPI), or LIVE TELEGRAM (scripts/telegram_driver.py against the real bot). Use for feature verification, E2E checks, regression repros, and post-change validation."
disable-model-invocation: true
argument-hint: "[feature or behavior to verify]"
allowed-tools: Read, Grep, Bash, Glob, Write
---

# Verify Lemon

A runbook for verifying lemon behavior end to end. Work in three tiers and
**always prefer the lowest tier that can answer the question** — most claims
about routing, sessions, runs, delivery, and transport plumbing never need
real Telegram.

| Tier | What it exercises | When |
|------|-------------------|------|
| 1 DIRECT | Router, sessions, runs, bus events, control plane, delivery funnel | Default. Anything not Telegram-wire-specific |
| 2 FAKE TELEGRAM | The real Telegram transport + outbound, hermetically (no network) | Buttons, approvals, forum topics, markdown chunking, offset/poller semantics |
| 3 LIVE TELEGRAM | Real Bot API + real chat UX | Only for wire-level/UX claims the fake cannot prove |

If `$ARGUMENTS` is provided, scope the verification session to that feature.

## Tier 1 — DIRECT (no Telegram)

### Attaching to a running instance

Discover the node name and cookie from the beam process args (or fall back to
`bin/lemon` defaults: node `lemon`, cookie `lemon_gateway_dev_cookie`, control
plane 4040, web 4080, sim UI 4090):

More than one beam can be running (production + a disposable instance you
started, e.g. via `scripts/product_smoke_local`). NEVER pick one blindly —
list them, check the registered names, and select the node you actually mean:

```bash
epmd -names                    # every distributed node on this machine
ps -eo pid,args | grep beam.smp | grep -v grep | grep -o '\-sname [^ ]*'
```

Then extract the cookie from the args of that specific node's process:

```bash
# -sname and -setcookie are adjacent "<flag>\n<value>" pairs in the beam args
NODE=lemon_bot   # <- the node you chose above, not just "the first beam"
ARGS=$(ps -eo args | grep beam.smp | grep -v grep | grep -- "-sname[= ]$NODE" | head -1 | tr ' ' '\n')
COOKIE=$(echo "$ARGS" | grep -A1 '^-setcookie$' | tail -1)   # NEVER echo/print this
```

The read-only-on-production rule below depends on this selection being right:
if two nodes are up and you are about to mutate state, double-check you are
attached to the disposable one (its name will look like `product_smoke_<pid>`
or whatever `--sname` you passed).

Non-interactive one-shot eval on the node (the expression runs in a fresh
process on the remote node, so a subscribe + `receive` in one expression
works):

```bash
elixir --sname "probe_$$" --cookie "$COOKIE" \
  --rpc-eval "$NODE@$(hostname -s)" \
  'LemonCore.RunStore.list_sessions() |> length() |> IO.inspect(label: "sessions")'
```

For interactive introspection use `iex --sname attach_$$ --cookie "$COOKIE"
--remsh "$NODE@$(hostname -s)"`.

**Read-only by default.** Against the user's production node, restrict
yourself to inspection (`:sys.get_state/1`, store reads, `Bus.subscribe`).
Anything that starts runs or sends messages belongs on a disposable instance.

### Control-plane WebSocket (port 4040)

An unauthenticated local connect gets the operator role with all scopes
(`parse_role(_) -> :operator` in `LemonControlPlane.Auth.Authorize`), so a
plain WS client can drive everything. Frames are
`{"type":"req","id":...,"method":...,"params":{...}}`; the server answers
`hello-ok` to `connect` and `{"type":"res","id":...}` to requests. Useful
methods (exact names from `LemonControlPlane.Methods.Registry`):

- `connect` → `hello-ok` handshake (send `{"client":{"id":...,"name":...}}`)
- `chat.send` — params `sessionKey` (required), `prompt`, optional `agentId`, `queueMode`
- `agent` — params `prompt` (required), `engine_id`, `session_key`, `model`, `idempotency_key`; returns `run_id`
- `agent.wait` — params `runId`, `timeoutMs`; blocks until the run completes
- `events.subscribe` — params `topics` (allowed: `all`, `system`, `cron`, `nodes`, `presence`, `exec_approvals`, `channels`, `goals`, plus `run:<id>` / `runId`)
- `sessions.list` — params `limit`, `offset`, `agentId`
- `logs.tail` — params `limit` (max 1000), `level`

Minimal probe with python-websockets (no install needed via uv; `websocat` works
too if present):

```bash
uv run --with websockets python - <<'PY'
import asyncio, json, websockets

async def main():
    async with websockets.connect("ws://127.0.0.1:4040/ws") as ws:
        async def req(id_, method, params):
            await ws.send(json.dumps(
                {"type": "req", "id": id_, "method": method, "params": params}))

        async def recv_until(pred):
            while True:
                frame = json.loads(await ws.recv())
                if pred(frame):
                    return frame

        await req("c1", "connect", {"client": {"id": "verify", "name": "Verify"}})
        await recv_until(lambda f: f.get("type") == "hello-ok")

        await req("a1", "agent", {"prompt": "ping", "engine_id": "echo",
                                  "session_key": "agent:verify:main"})
        run = await recv_until(lambda f: f.get("type") == "res" and f.get("id") == "a1")
        run_id = run["payload"]["run_id"]

        await req("w1", "agent.wait", {"runId": run_id, "timeoutMs": 10000})
        done = await recv_until(lambda f: f.get("type") == "res" and f.get("id") == "w1")
        assert done["payload"]["answer"] == "Echo: ping", done
        print("echo run ok:", run_id)

asyncio.run(main())
PY
```

### Observing runs on the bus

From an attached node (or `--rpc-eval`), subscribe to
`LemonCore.Bus` topics — `"run:<run_id>"` and `"session:<session_key>"` carry
typed events (`LemonCore.Event` structs; catalog in
`docs/platform/bus-events.md`):

```bash
elixir --sname "probe_$$" --cookie "$COOKIE" --rpc-eval "$NODE@$(hostname -s)" '
LemonCore.Bus.subscribe("session:agent:verify:main")
receive do
  %LemonCore.Event{} = event -> IO.inspect({event.type, event.ts_ms}, label: "event")
after
  30_000 -> IO.puts("no event in 30s")
end
'
```

### Observing outbound channel delivery (ChannelDelivery)

Every `LemonChannels.Dispatcher.dispatch/1` (success and failure) now emits:

- telemetry `[:lemon, :channels, :dispatch]` — measurements `%{count: 1, duration: native}`, metadata `%{channel_id, account_id, kind, intent_id, run_id, session_key, ok}`
- a typed `LemonCore.Events.ChannelDelivery` broadcast as `:channel_delivery` on the `"channels"` bus topic (fields: `intent_id`, `run_id`, `session_key`, `channel_id`, `account_id`, `peer_kind`, `peer_id`, `thread_id`, `kind`, `text_preview` ≤200 chars, `ok`, `error`, `duration_ms`, `ts_ms`)
- a control-plane WS event `channel.delivery` (camelCase payload), received by clients subscribed via `events.subscribe` with `topics: ["channels"]`

So "did lemon actually deliver a reply to the channel?" is answerable without
touching the channel:

```bash
elixir --sname "probe_$$" --cookie "$COOKIE" --rpc-eval "$NODE@$(hostname -s)" '
LemonCore.Bus.subscribe("channels")
receive do
  %LemonCore.Event{type: :channel_delivery, payload: p} ->
    IO.inspect({p.channel_id, p.kind, p.ok, p.text_preview}, label: "delivery")
after
  30_000 -> IO.puts("no delivery in 30s")
end
'
```

### Injecting synthetic channel-shaped inbound

To exercise the router pipeline with a channel-shaped message (bypassing any
transport), build a `%LemonCore.InboundMessage{}` (enforced keys:
`channel_id`, `account_id`, `peer`, `message`) and hand it to
`LemonChannels.Runtime.submit_inbound/1` — **on a disposable/test instance
only**, since this starts a real run and a real outbound delivery:

```elixir
LemonChannels.Runtime.submit_inbound(%LemonCore.InboundMessage{
  channel_id: "telegram",
  account_id: "default",
  peer: %{kind: :dm, id: "310001", thread_id: nil},
  sender: %{id: "310001", username: "probe", display_name: "Probe"},
  message: %{id: "1", text: "hello from probe", timestamp: System.system_time(:second), reply_to_id: nil},
  raw: %{},
  meta: %{}
})
```

### Deterministic agents-under-test

- **Echo engine** — `LemonGateway.Engines.Echo`, engine id `"echo"`; any run answers `"Echo: <prompt>"` with no model, no credentials. Select via `engine_id: "echo"` on `agent` / run submission.
- **`LemonPlatformTest.FakeLLM`** — scripted stream function for `LemonAgent` loops in ExUnit: `FakeLLM.script([{:tool_call, "name", %{...}}, {:text, "answer"}])` yields a conforming provider stream, letting you assert tool-call handling without a network.

### Spinning a disposable instance

`scripts/product_smoke_local` is the reference recipe (dev boot; `--release`
for CI-parity release boot). It is safe next to the production node: temp
`HOME` (never the real `~/.lemon`), unique `--sname product_smoke_$$` +
random cookie, dynamic free ports, isolated store/dotenv, kills only what it
started. Run it as-is for a green/red product check, or copy its isolation
levers for a custom instance:

```bash
scripts/product_smoke_local            # PASS/FAIL + .lemon/proofs/product-smoke-local-latest.json
PRODUCT_SMOKE_KEEP_WORKDIR=1 scripts/product_smoke_local   # keep workdir for debugging
```

Port-collision env knobs (all honored by `config/runtime.exs`):
`LEMON_CONTROL_PLANE_PORT`, `LEMON_WEB_PORT`, `LEMON_SIM_UI_PORT`,
`LEMON_GATEWAY_HEALTH_PORT=0`, `LEMON_ROUTER_HEALTH_PORT=0` (0 = ephemeral
bind, avoids the running instance's fixed 4042), plus `LEMON_STORE_PATH`,
`LEMON_DOTENV_DIR`, `LEMON_GATEWAY_NODE_NAME`, `LEMON_GATEWAY_NODE_COOKIE`.

## Tier 2 — FAKE TELEGRAM (hermetic transport testing)

Prefer this tier for anything Telegram-specific that does not require the real
wire: inline buttons/callback queries, approval flows, forum-topic threading,
markdown chunking/rendering, poller offset semantics, file transfer — all
without real-TG flakiness, rate limits, or credentials.

`LemonChannels.Telegram.FakeAPI`
(`apps/lemon_channels/lib/lemon_channels/telegram/fake_api.ex`) mirrors every
api_mod function the real transport calls. Select it exactly like an operator
would:

```toml
[gateway.telegram]
bot_token = "fake-token"          # accepted, never recorded
api_mod = "LemonChannels.Telegram.FakeAPI"
```

or in ExUnit, pass the module straight to the transport (see
`apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_fake_api_test.exs`
for the full boot + RouterBridge stub recipe):

```elixir
LemonChannels.Adapters.Telegram.Transport.start_link(
  config: %{bot_token: "fake-token", api_mod: LemonChannels.Telegram.FakeAPI}
)
```

Drive it — fabricate inbound, await captured outbound:

```elixir
# Inbound: enqueue a realistic message update (auto bot_command entity for "/...")
FakeAPI.simulate_message(4242, "/status")
FakeAPI.simulate_message(-100_320_002, "in a topic", message_thread_id: 777)
FakeAPI.simulate_callback_query(4242, "approve|once", message_id: 1000)

# Outbound: block until the transport calls the API, then inspect
{:ok, %{fun: :send_message, args: [chat_id, text, opts, parse_mode]}} =
  FakeAPI.await_send(:send_message, 10_000)

FakeAPI.sent()                      # all captured calls %{fun, args, at_ms}
FakeAPI.stub(:get_chat_member, {:ok, %{"ok" => true, "result" => %{"status" => "administrator"}}})
FakeAPI.put_file("file-1", "bytes") # get_file/2 + download_file/2 round-trip
FakeAPI.reset()                     # queue + captures + stubs + files (counters survive, safe mid-poll)
```

Against a test-booted live instance with the fake configured, the same driving
API works over `--rpc-eval` (the FakeAPI GenServer is name-registered on that
node; the transport lazily boots it):

```bash
elixir --sname "probe_$$" --cookie "$COOKIE" --rpc-eval "$TESTNODE@$(hostname -s)" \
  'LemonChannels.Telegram.FakeAPI.simulate_message(4242, "/status") |> Map.get("update_id") |> IO.inspect()'
elixir --sname "probe_$$" --cookie "$COOKIE" --rpc-eval "$TESTNODE@$(hostname -s)" \
  'LemonChannels.Telegram.FakeAPI.await_send(:send_message, 10_000) |> inspect() |> IO.puts()'
```

The house smoke proves the whole loop (string-config api_mod resolution,
inbound round trip, offset advance, callback answer, outbound delivery) and
writes a proof artifact:

```bash
MIX_ENV=test mix run scripts/live_fake_telegram_smoke.exs
# -> .lemon/proofs/fake-telegram-smoke-latest.json, exit 1 on any failed check
```

## Tier 3 — LIVE TELEGRAM

Only when the claim is about the real wire or real chat UX (Bot API behavior,
actual rendering in clients, live latency). Use `scripts/telegram_driver.py`
— a Telethon library + CLI sharing the matrix harness's credential loading
(`~/.zeebot/api_keys/telegram.txt`; Bot API token from
`LEMON_TELEGRAM_BOT_TOKEN`/`TELEGRAM_BOT_TOKEN` env, the credentials file, or
the lemon secrets store — never printed).

CLI subcommands (all take `--credentials --group --bot --repo-root --json`;
chat commands add `--chat --topic-id`; waiting commands add `--timeout
--idle-timeout --limit`):

```bash
uv run scripts/telegram_driver.py topic-create "[verify] my probe" --json
uv run scripts/telegram_driver.py send-and-await "reply with exactly OK" --topic-id "$TOPIC" --json
uv run scripts/telegram_driver.py await --topic-id "$TOPIC" --after-id 1234 --json
uv run scripts/telegram_driver.py send "hello" --chat bot --json          # DM to the bot
uv run scripts/telegram_driver.py press-button --message-id 1240 "Approve once" --json
uv run scripts/telegram_driver.py topic-delete "$TOPIC" --json
uv run scripts/telegram_driver.py topic-cleanup "[verify]" --dry-run --json
```

Exit codes: 0 ok (`await`/`send-and-await` require ≥1 reply), 1 `ok:false`,
2 error (`--json` prints `{"ok":false,"error":...}`). Library use:
`async with TelegramDriver() as driver:` with `send` / `await_replies` /
`send_and_await` / `press_button` / `create_topic` / `delete_topic` /
`cleanup_topics` (see the module docstring).

Test-group conventions:

- Target the **Lemonade Stand** group (default `-1003842984060`, bot `zeebot_lemon_bot`).
- Create **temp topics with a recognizable prefix** (e.g. `[verify]` or `[adhoc]`), do all probing inside them.
- **ALWAYS clean up your topics** when done: `topic-delete` each one, or `topic-cleanup "<your-prefix>"` (it never touches the General topic, id 1; run `--dry-run` first).

Related tooling: `scripts/live_telegram_matrix.py` for the fixed live scenario
matrix (DM/topic isolation/cancel/approval/markdown/long-output), the
`stress-test-lemon` command for the 8-test parallel stress run, and
`.claude/skills/telegram-gateway-debug-loop/SKILL.md` for deep debugging with
gateway debug logs + remote shell.

## Safety rules

- **Never print secrets.** No bot tokens, api_id/api_hash, session strings, or Erlang cookies in output, code, commits, or reports. Credentials stay in `~/.zeebot/api_keys/telegram.txt` and the lemon secrets store — reference paths, hold values only in shell variables/memory.
- **Never touch the user's real `~/.lemon` or the production node.** Do not kill `lemon_bot@<host>`, do not bind its ports (4040/4080/4042), do not start runs or send messages on it. Attach read-only at most; anything mutating runs on a disposable instance (`scripts/product_smoke_local` isolation levers).
- **Always clean up:** temp forum topics (`topic-cleanup`), disposable instances (product_smoke_local cleans up after itself; kill only pids you started), and any transports/fakes you booted in a VM (`GenServer.stop`, `FakeAPI.reset()`).
- **Prefer lower tiers.** Tier 1 for routing/session/run/delivery claims, Tier 2 for Telegram transport semantics, Tier 3 only when the real wire is the thing under test.
