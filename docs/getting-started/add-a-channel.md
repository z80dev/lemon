# Add a channel

A channel is whatever carries messages between a person and your agent: a
terminal, Telegram, Discord, email, your company's internal chat. This guide
goes from the console loop you already have to a registered
`LemonChannels.Plugin`, which is the platform's channel extension point and the
best first contribution to Lemon itself.

Start from the project in [Build your first agent](build-your-first-agent.md).

## The console you already have

`lib/my_agent/console.ex` is a channel in the loose sense. It is worth reading
first, because it demonstrates the part every channel needs: consuming the
agent's event stream.

`MyAgent.Agent.ask/2` blocks and returns the final answer, which is all a script
needs. A channel wants to show the answer arriving, and to say "running
word_count…" while a tool works. `AgentCore.subscribe/2` is how:

```elixir
_unsubscribe = AgentCore.subscribe(agent, self())
:ok = AgentCore.prompt(agent, "hello")

receive do
  {:agent_event, {:message_update, _message, {:text_delta, _index, delta, _partial}}} ->
    IO.write(delta)

  {:agent_event, {:tool_execution_start, _id, name, _args}} ->
    IO.write("\n  [#{name}…]")

  {:agent_event, {:agent_end, _messages}} ->
    IO.puts("")
end
```

The full event list is in `AgentCore.Types.agent_event/0`. The ones a channel
usually cares about are `:message_update` (text arriving), the three
`:tool_execution_*` events, `:agent_end` and `:error`.

## Stepping up to a Plugin

The console writes to stdout directly. A `LemonChannels.Plugin` instead
*registers* with the channel runtime, which then gives you a registry entry, an
outbox with delivery retries, a dispatcher, and a place in the platform's status
reporting. Same idea, with the operational parts already built.

You can generate the whole thing:

```bash
mix lemon.new my_agent --channel
```

or add it to an existing project by following the rest of this guide.

### 1. Add the dependencies

In `mix.exs`:

```elixir
{:lemon_channels, path: "/path/to/lemon/apps/lemon_channels"},
# {:lemon_channels, "~> 0.1"},

{:lemon_platform_test,
 path: "/path/to/lemon/apps/lemon_platform_test", only: :test, runtime: false},
# {:lemon_platform_test, "~> 0.1", only: :test, runtime: false}
```

`lemon_platform_test` is the contract-test kit. It is test-only and it is not
optional in spirit — the compliance suite is how you find out that your adapter
works but the platform cannot see it.

### 2. Write the adapter

`lib/my_agent/channel.ex`. This one delivers to stdout, so it needs no
credentials and you can actually run it:

```elixir
defmodule MyAgent.Channel do
  @behaviour LemonChannels.Plugin

  alias LemonChannels.OutboundPayload
  alias LemonCore.InboundMessage

  @impl true
  def id, do: "console"

  @impl true
  def meta do
    %{
      label: "Console",
      capabilities: %{edit_support: false, chunk_limit: 4_000},
      docs: nil
    }
  end

  @impl true
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_nothing, []}}
  end

  @doc false
  def start_nothing, do: :ignore

  def register do
    LemonChannels.Application.register_and_start_adapter(__MODULE__, [])
  end

  @impl true
  def normalize_inbound(%{"user" => user, "text" => text})
      when is_binary(user) and is_binary(text) and user != "" do
    {:ok,
     InboundMessage.new(
       channel_id: id(),
       account_id: "local",
       peer: %{kind: :dm, id: user, thread_id: nil},
       sender: %{id: user, username: user, display_name: user},
       message: %{id: nil, text: text, timestamp: nil, reply_to_id: nil},
       raw: %{"user" => user, "text" => text}
     )}
  end

  def normalize_inbound(_raw), do: {:error, :unsupported_payload}

  @impl true
  def deliver(%OutboundPayload{kind: :text, peer: %{id: peer_id}, content: content})
      when is_binary(content) do
    IO.puts("[console -> #{peer_id}] #{content}")
    {:ok, %{delivered_at: System.system_time(:millisecond)}}
  end

  def deliver(%OutboundPayload{kind: kind}), do: {:error, {:unsupported_kind, kind}}

  @impl true
  def gateway_methods, do: []
end
```

### 3. Register it at boot

In `lib/my_agent/application.ex`, after the supervisor starts:

```elixir
:ok = MyAgent.Channel.register()
```

That call is the whole integration story. The platform has no compile-time
knowledge of your module; a channel living in its own repository, depending on
`lemon_channels` from Hex, registers exactly the same way.

## The four rules that are not in the signatures

The callback types cannot express these, and the platform relies on all four.

**`id/0` is an identity, not a label.** A lowercase slug matching
`~r/^[a-z][a-z0-9_-]*$/`. It is the registry key, it travels in
`InboundMessage.channel_id` and `OutboundPayload.channel_id`, and it is
persisted in routing state — so renaming it later strands existing bindings.
Anything a human reads belongs in `meta/0`'s `:label`.

**`id/0` and `meta/0` are pure.** Same value every call, no config lookups, no
I/O. `meta/0` is hit on every status query.

**`normalize_inbound/1` must not raise.** It receives whatever the transport
handed you: a truncated webhook body, a message type you have never seen, a
payload from a version of the upstream API that shipped this morning. Return
`{:error, reason}` for anything you do not understand. Raising takes down the
process reading from the network, which usually means a reconnect loop — and the
offending message is still waiting when you come back.

**`deliver/1` reports failure rather than raising**, including for payload kinds
you do not support. The renderer will attempt `:edit` against any channel whose
capabilities claim `edit_support`, and the outbox retries and reports. Terminate
the adapter over one bad payload and every other conversation on that channel
goes with it. Hence the catch-all clause at the end of `deliver/1`.

One more thing worth internalising about `meta/0`: **omit a capability rather
than inventing a value for it.** `LemonChannels.Capabilities.from_legacy/1`
treats anything absent as unsupported, which is the safe direction. Claiming
`edit_support` you do not have produces edit attempts that silently fail.

## 4. Run the compliance suite

`test/my_agent/channel_test.exs`:

```elixir
defmodule MyAgent.ChannelComplianceTest do
  use LemonPlatformTest.PluginCase,
    async: false,
    adapter: MyAgent.Channel,
    deliver_probe: {__MODULE__, :unsupported_payload},
    inbound_fixtures: {__MODULE__, :inbound_fixtures},
    hostile_inbound: [
      %{"user" => "", "text" => "empty peer"},
      %{"user" => "alice"},
      %{"text" => "no sender"}
    ]

  alias LemonChannels.OutboundPayload

  def unsupported_payload(_context) do
    %OutboundPayload{
      channel_id: MyAgent.Channel.id(),
      account_id: "local",
      peer: %{kind: :dm, id: "alice", thread_id: nil},
      kind: :reaction,
      content: "thumbs_up"
    }
  end

  def inbound_fixtures(_context) do
    [
      %{"user" => "alice", "text" => "hello"},
      %{"user" => "bob", "text" => ""}
    ]
  end
end
```

```bash
mix test test/my_agent/channel_test.exs
```

Fifteen tests, covering the four rules above plus a registration round-trip
against the real registry.

Two options deserve a note:

- **`:deliver_probe` has no default, on purpose.** Only you know which payload
  cannot reach a real user. A kind your adapter does not support is usually the
  right choice — a compliance suite that posts to a live Telegram bot is worse
  than no compliance suite.
- **`async: false` is required** whenever `:registry` is enabled (the default),
  because the suite registers and unregisters in the node-global registry. It
  restores whatever registration it found.

## What the platform does with a registered channel

Once registered, an adapter is reachable by `LemonChannels.Registry`, its
capabilities feed the renderer's chunking and edit decisions, and outbound
messages go through `LemonChannels.Outbox`, which owns retries and delivery
acknowledgements. Inbound messages that `normalize_inbound/1` accepts are handed
to the router through `LemonCore.RouterBridge`.

None of that requires more code from you: the six callbacks are the entire
surface.

## Writing a real channel

The built-in adapters — Telegram, Discord, WhatsApp, XMTP, email — are the
worked examples, and `LemonPlatformTest.PluginCase`'s moduledoc is the contract
in prose. A new channel adapter is the ideal first contribution to Lemon; if you
build one, it can equally live in its own repository, exactly like the X
integration does.

## Next

- [Persist memory](persist-memory.md) — keep what the conversation established.
