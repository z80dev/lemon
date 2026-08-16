# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
# This is an ExUnit CaseTemplate: the `using/1` quote block is intentionally
# large because it injects the entire compliance suite into the including test
# module. Splitting it would obscure the contract it exists to express.
defmodule LemonPlatformTest.PluginCase do
  @moduledoc """
  Compliance suite for `LemonChannels.Plugin` implementations.

  ## What a plugin is

  A channel plugin connects Lemon to a messaging surface — Telegram, Discord,
  WhatsApp, XMTP, X, your company's internal chat. It is the platform's most
  used extension point, and the one with the most exposure to input you did not
  write: everything arriving from the network passes through `normalize_inbound/1`
  before the platform will look at it.

  A plugin is a module, not a process. It *describes* a process tree through
  `child_spec/1`, which `LemonChannels` starts under its own supervisor once the
  plugin is registered. Registration can happen at boot from configuration, or
  at runtime from another application:

      LemonChannels.Application.register_and_start_adapter(MyApp.ChannelAdapter, [])

  That runtime path is how a satellite package (an integration living in its own
  repo, depending on `lemon_channels` from Hex) plugs itself in without the
  platform knowing it exists. This suite exercises it, because "my adapter works
  but the platform can't see it" is the most common way a third-party channel
  fails.

  ## The contract

  ### `id/0` is an identity, not a label

  A short, stable, lowercase slug matching `~r/^[a-z][a-z0-9_-]*$/`. It is the
  registry key, it appears in `LemonCore.InboundMessage.channel_id` and
  `LemonChannels.OutboundPayload.channel_id`, and it ends up in persisted
  routing state — so changing it later strands existing bindings. It must be
  pure: same value on every call, no configuration lookups.

  ### `meta/0` describes capabilities, and is also pure

  `%{label: binary, capabilities: map, docs: binary | nil}`. `:label` is what
  operators see. `:capabilities` is how the renderer decides whether it may edit
  a message instead of resending it, how long a chunk may be, whether voice or
  attachments are worth trying; `LemonChannels.Capabilities` interprets it.
  Callers hit `meta/0` on every status query, so it must not do I/O.

  ### `child_spec/1` is the standard OTP one

  Returns a child spec map with `:id` and `:start`. Return
  `%{id: __MODULE__, start: {SomeSupervisor, :start_link, [opts]}, type: :supervisor}`
  for a plugin with a process tree. A plugin that has nothing to run should
  still return a valid spec whose start function returns `:ignore` — the
  registry starts whatever you hand it.

  ### `normalize_inbound/1` must not raise

  It receives whatever the transport handed you: an incomplete webhook body, a
  message type you have never seen, a payload from a version of the upstream API
  that shipped this morning. Return `{:ok, %LemonCore.InboundMessage{}}` for
  something you understand and `{:error, reason}` for anything else. Raising
  takes down the process that was reading from the network, which usually means
  a reconnect loop, and the malformed message is still there when you come back.

  Messages you return must carry your own `channel_id` (the platform routes
  replies by it), a `peer` with `:kind` in `[:dm, :group, :channel]` and a
  binary `:id`, and a `message` map with a binary `:text`. For anything you
  normalize from a real update — the `:inbound_fixtures` you hand this suite —
  the peer id must also be non-empty, or the platform has nowhere to send the
  reply.

  ### `deliver/1` reports failure, it does not raise

  Given a `LemonChannels.OutboundPayload`, return `{:ok, delivery_ref}` or
  `{:error, reason}`. `delivery_ref` is opaque to the platform and is what the
  outbox hands back to whoever asked for the send. Unsupported payload kinds are
  an `{:error, _}`, not a crash: the renderer will try `:edit` on a channel that
  claimed `edit_support`, and a network hiccup must not take the adapter with
  it.

  ### `gateway_methods/0` may be empty

  A list of `%{name: binary, scopes: [atom], handler: module}` control-plane
  methods your channel adds. Most channels return `[]`.

  ## Minimal implementation

      defmodule MyApp.ChannelAdapter do
        @behaviour LemonChannels.Plugin

        alias LemonChannels.OutboundPayload
        alias LemonCore.InboundMessage

        @impl true
        def id, do: "my-channel"

        @impl true
        def meta do
          %{
            label: "My Channel",
            capabilities: %{edit_support: false, chunk_limit: 2_000},
            docs: "https://example.com/api"
          }
        end

        @impl true
        def child_spec(opts) do
          %{id: __MODULE__, start: {MyApp.Channel.Supervisor, :start_link, [opts]}, type: :supervisor}
        end

        @impl true
        def normalize_inbound(%{"chat" => %{"id" => chat_id}, "text" => text} = raw)
            when is_binary(text) do
          {:ok,
           InboundMessage.new(
             channel_id: id(),
             account_id: "default",
             peer: %{kind: :dm, id: to_string(chat_id), thread_id: nil},
             message: %{id: nil, text: text, timestamp: nil, reply_to_id: nil},
             raw: raw
           )}
        end

        def normalize_inbound(_raw), do: {:error, :unsupported_payload}

        @impl true
        def deliver(%OutboundPayload{kind: :text} = payload) do
          MyApp.Api.send_message(payload.peer.id, payload.content)
        end

        def deliver(%OutboundPayload{kind: kind}), do: {:error, {:unsupported_kind, kind}}

        @impl true
        def gateway_methods, do: []
      end

  ## Running the suite

      defmodule MyApp.ChannelAdapterComplianceTest do
        use LemonPlatformTest.PluginCase, async: false, adapter: MyApp.ChannelAdapter
      end

  `async: false` is required whenever `:registry` is enabled (the default),
  because the suite registers and unregisters the adapter in the node-global
  `LemonChannels.Registry`. It restores whatever registration it found.

  ## Options

    * `:adapter` — required, the plugin module under test.
    * `:registry` — round-trip the adapter through `LemonChannels.Registry`.
      Default `true`; requires `:lemon_channels` to be started.
    * `:start_adapter` — also exercise
      `LemonChannels.Application.register_and_start_adapter/2`, which starts
      your `child_spec/1` under the channels supervisor. Default `false`; only
      enable it if starting your tree in a test environment is harmless (no
      credentials, no outbound connections).
    * `:deliver_probe` — `{Module, :function}` returning an
      `%LemonChannels.OutboundPayload{}`, called with the test context. The
      suite asserts `deliver/1` answers `{:ok, _}` or `{:error, _}` for it.
      **There is no default, on purpose**: only you know which payload cannot
      reach a real user. A payload with a `:kind` your adapter does not support
      is usually the right choice.
    * `:inbound_fixtures` — `{Module, :function}` returning a list of raw values
      that must normalize successfully. The suite checks the resulting
      `InboundMessage` structs. Optional, but this is where you prove your
      adapter understands its own wire format.
    * `:hostile_inbound` — extra raw values that must *not* raise, appended to
      the built-in list (`nil`, `%{}`, `""`, integers, unexpected shapes).

  ## Known gaps in the behaviour

    * `meta/0`'s `:capabilities` map is typed `map()`; the keys the renderer
      actually reads (`:edit_support`, `:chunk_limit`, …) are documented only by
      example, and `LemonChannels.Capabilities.from_legacy/1` fills in defaults
      for anything missing. The suite therefore checks the shape of `meta/0` but
      cannot check that a capability claim is honest.
    * **Nothing forbids an unroutable `InboundMessage`.** `normalize_inbound/1`
      may answer `{:ok, message}` with an empty `peer.id`, and at least one
      built-in adapter does exactly that when handed a truncated update — the
      message then flows into routing and fails much later. The suite enforces
      a non-empty peer id only for `:inbound_fixtures`, since tightening the
      hostile-input path would fail an adapter the behaviour currently permits.
    * `deliver/1`'s `delivery_ref` is `term()`. Adapters return wildly different
      things (a message id, a map, an API response). Nothing consumes it
      generically, so nothing can.
  """

  use ExUnit.CaseTemplate

  @hostile_inbound [
    nil,
    %{},
    "",
    "not a map",
    42,
    [],
    %{"update_id" => 1},
    %{"message" => %{"text" => nil}},
    %{message: %{text: "atom keys where strings were expected"}},
    %{"deeply" => %{"nested" => %{"but" => %{"meaningless" => true}}}},
    # A list or a map where the adapter expects a string. This is not exotic:
    # `?subject[]=a&subject[]=b` through `Plug.Parsers`' urlencoded parser
    # produces the first, and any JSON body can produce the second. An adapter
    # that reaches for `String.trim/1` on whatever it finds raises here, which
    # is exactly the class of bug this list exists to catch — one of the
    # built-ins did, on four separate fields.
    %{"from" => "a@b.c", "text" => ["one", "two"]},
    %{"from" => "a@b.c", "subject" => %{"nested" => "object"}},
    %{"message" => %{"text" => ["chunked"], "caption" => %{"a" => 1}}},
    %{"from" => 42, "text" => 42, "html" => [%{}]}
  ]

  @doc """
  The raw inbound values every plugin is probed with.

  Exposed so you can reuse them in your adapter's own tests.
  """
  @spec hostile_inbound() :: [term()]
  def hostile_inbound, do: @hostile_inbound

  @doc """
  Asserts `adapter.meta/0` has the shape the channel registry expects.

  Lives here rather than in the generated test so that the assertions run
  against a `module()` the compiler cannot constant-fold: adapters usually
  return a literal map from `meta/0`, and checking `docs == nil` on a literal
  makes Elixir's type checker (rightly) complain that the comparison is decided
  at compile time.
  """
  @spec assert_meta!(module()) :: :ok
  def assert_meta!(adapter) when is_atom(adapter) do
    meta = adapter.meta()

    assert is_map(meta), "meta/0 must return a map, got: #{inspect(meta)}"

    assert is_binary(meta[:label]) and meta[:label] != "",
           "meta.label must be a non-empty binary, got: #{inspect(meta[:label])}"

    assert is_map(meta[:capabilities]),
           "meta.capabilities must be a map, got: #{inspect(meta[:capabilities])}"

    docs = Map.get(meta, :docs)

    assert docs == nil or is_binary(docs),
           "meta.docs must be a binary or nil, got: #{inspect(docs)}"

    :ok
  end

  using opts do
    LemonPlatformTest.require_dep!("PluginCase", LemonChannels.Plugin, :lemon_channels)

    adapter = Keyword.fetch!(opts, :adapter)
    registry? = Keyword.get(opts, :registry, true)
    start_adapter? = Keyword.get(opts, :start_adapter, false)
    deliver_probe = Keyword.get(opts, :deliver_probe)
    inbound_fixtures = Keyword.get(opts, :inbound_fixtures)
    hostile_inbound = Keyword.get(opts, :hostile_inbound, [])
    label = Macro.to_string(adapter)

    quote do
      @adapter unquote(adapter)
      @deliver_probe unquote(deliver_probe)
      @inbound_fixtures unquote(inbound_fixtures)
      @extra_hostile_inbound unquote(hostile_inbound)

      describe unquote(label <> " behaviour declaration") do
        test "declares LemonChannels.Plugin" do
          assert LemonPlatformTest.declares_behaviour?(@adapter, LemonChannels.Plugin),
                 "#{inspect(@adapter)} must declare `@behaviour LemonChannels.Plugin`"
        end

        test "exports every required callback" do
          assert LemonPlatformTest.missing_callbacks(@adapter, LemonChannels.Plugin) == []
        end
      end

      describe unquote(label <> " id/0") do
        test "is a stable, lowercase slug" do
          id = @adapter.id()

          assert is_binary(id), "id/0 must return a binary, got: #{inspect(id)}"
          assert id != ""

          assert Regex.match?(~r/^[a-z][a-z0-9_-]*$/, id),
                 "channel id #{inspect(id)} must match ~r/^[a-z][a-z0-9_-]*$/"

          assert @adapter.id() == id, "id/0 must return the same value on every call"
        end
      end

      describe unquote(label <> " meta/0") do
        test "describes the channel" do
          LemonPlatformTest.PluginCase.assert_meta!(@adapter)
        end

        test "is pure" do
          assert @adapter.meta() == @adapter.meta()
        end

        test "capabilities survive the platform's capability parser" do
          capabilities = LemonChannels.Capabilities.from_legacy(@adapter.meta().capabilities)

          assert is_map(capabilities),
                 "LemonChannels.Capabilities.from_legacy/1 rejected this adapter's capabilities"

          for {type, capability} <- capabilities do
            assert is_atom(type)

            assert %LemonChannels.Capabilities.Capability{} = capability,
                   "parsed capability #{inspect(type)} is not a Capability struct"
          end
        end
      end

      describe unquote(label <> " child_spec/1") do
        test "returns a startable child spec" do
          spec = @adapter.child_spec([])

          assert %{id: _, start: {module, function, args}} = spec
          assert is_atom(module) and is_atom(function) and is_list(args)
          assert Code.ensure_loaded?(module), "#{inspect(module)} is not loadable"

          assert function_exported?(module, function, length(args)),
                 "#{inspect(module)}.#{function}/#{length(args)} is not exported"

          # Supervisor normalisation is what the channels supervisor performs.
          assert %{id: _, start: _} = Supervisor.child_spec(spec, [])
        end
      end

      describe unquote(label <> " normalize_inbound/1") do
        test "answers {:ok, message} or {:error, reason} for hostile input" do
          for raw <- LemonPlatformTest.PluginCase.hostile_inbound() ++ @extra_hostile_inbound do
            result =
              try do
                @adapter.normalize_inbound(raw)
              rescue
                exception ->
                  flunk("""
                  normalize_inbound/1 raised on #{inspect(raw)}:

                      #{Exception.message(exception)}

                  Return {:error, reason} for input you do not understand.
                  """)
              catch
                kind, reason ->
                  flunk("normalize_inbound/1 threw #{kind} #{inspect(reason)} on #{inspect(raw)}")
              end

            case result do
              {:ok, %LemonCore.InboundMessage{} = message} ->
                lemon_assert_inbound_message(message)

              {:error, _reason} ->
                :ok

              other ->
                flunk("""
                normalize_inbound/1 must return {:ok, %LemonCore.InboundMessage{}} or {:error, reason}.

                Input:  #{inspect(raw)}
                Output: #{inspect(other)}
                """)
            end
          end
        end

        if unquote(inbound_fixtures != nil) do
          test "normalizes the adapter's own fixtures", context do
            fixtures = LemonPlatformTest.resolve(@inbound_fixtures, context)

            assert fixtures != [], ":inbound_fixtures returned no fixtures"

            for raw <- fixtures do
              assert {:ok, %LemonCore.InboundMessage{} = message} =
                       @adapter.normalize_inbound(raw),
                     "fixture did not normalize: #{inspect(raw, limit: 10)}"

              lemon_assert_inbound_message(message, true)
            end
          end
        end
      end

      describe unquote(label <> " deliver/1") do
        test "is exported with arity 1" do
          assert Code.ensure_loaded?(@adapter)
          assert function_exported?(@adapter, :deliver, 1)
        end

        if unquote(deliver_probe != nil) do
          test "answers {:ok, ref} or {:error, reason}", context do
            payload = LemonPlatformTest.resolve(@deliver_probe, context)

            assert %LemonChannels.OutboundPayload{} = payload,
                   ":deliver_probe must return a %LemonChannels.OutboundPayload{}"

            result =
              try do
                @adapter.deliver(payload)
              rescue
                exception ->
                  flunk("""
                  deliver/1 raised on #{inspect(payload.kind)}:

                      #{Exception.message(exception)}

                  Delivery failures must come back as {:error, reason}.
                  """)
              end

            assert match?({:ok, _}, result) or match?({:error, _}, result),
                   "deliver/1 must return {:ok, ref} or {:error, reason}, got: #{inspect(result)}"
          end
        end
      end

      describe unquote(label <> " gateway_methods/0") do
        test "returns well-formed method descriptors" do
          methods = @adapter.gateway_methods()

          assert is_list(methods), "gateway_methods/0 must return a list"

          for method <- methods do
            assert is_map(method), "each gateway method must be a map, got: #{inspect(method)}"
            assert is_binary(method[:name]) and method[:name] != ""
            assert is_list(method[:scopes]) and Enum.all?(method[:scopes], &is_atom/1)
            assert is_atom(method[:handler]) and Code.ensure_loaded?(method[:handler])
          end
        end
      end

      if unquote(registry?) do
        describe unquote(label <> " registration round-trip") do
          setup do
            :ok = LemonPlatformTest.PluginCase.ensure_channels_started!()
            previous = LemonChannels.Registry.get_plugin(@adapter.id())

            if previous, do: LemonChannels.Registry.unregister(@adapter.id())

            on_exit(fn ->
              LemonChannels.Registry.unregister(@adapter.id())
              if previous, do: LemonChannels.Registry.register(previous)
            end)

            :ok
          end

          test "the registry can find the adapter, its meta and its capabilities" do
            id = @adapter.id()

            assert :ok = LemonChannels.Registry.register(@adapter)

            assert LemonChannels.Registry.get_plugin(id) == @adapter
            assert @adapter in LemonChannels.Registry.list_plugins()
            assert LemonChannels.Registry.get_meta(id) == @adapter.meta()
            assert LemonChannels.Registry.get_capabilities(id) == @adapter.meta().capabilities
            assert is_map(LemonChannels.Registry.get_capabilities_new(id))

            assert id in LemonChannels.Registry.status().configured
            assert {^id, %{type: ^id}} = List.keyfind(LemonChannels.Registry.list(), id, 0)
          end

          test "registering the same id twice is refused, not silently swapped" do
            assert :ok = LemonChannels.Registry.register(@adapter)
            assert {:error, :already_registered} = LemonChannels.Registry.register(@adapter)
            assert LemonChannels.Registry.get_plugin(@adapter.id()) == @adapter
          end

          test "unregistering removes the adapter" do
            id = @adapter.id()

            assert :ok = LemonChannels.Registry.register(@adapter)
            assert :ok = LemonChannels.Registry.unregister(id)

            assert LemonChannels.Registry.get_plugin(id) == nil
            assert LemonChannels.Registry.get_meta(id) == nil
            refute id in LemonChannels.Registry.status().configured
          end

          if unquote(start_adapter?) do
            test "register_and_start_adapter/2 registers and starts the adapter" do
              id = @adapter.id()

              assert :ok = LemonChannels.Application.register_and_start_adapter(@adapter, [])
              assert LemonChannels.Registry.get_plugin(id) == @adapter

              on_exit(fn -> LemonChannels.Application.stop_adapter(@adapter) end)
            end
          end
        end
      end

      defp lemon_assert_inbound_message(message, routable? \\ false)

      defp lemon_assert_inbound_message(%LemonCore.InboundMessage{} = message, routable?) do
        assert message.channel_id == @adapter.id(),
               "InboundMessage.channel_id must be #{inspect(@adapter.id())}, got #{inspect(message.channel_id)}"

        assert is_binary(message.account_id), "InboundMessage.account_id must be a binary"
        assert is_map(message.peer), "InboundMessage.peer must be a map"

        assert message.peer[:kind] in [:dm, :group, :channel],
               "peer.kind must be :dm, :group or :channel, got #{inspect(message.peer[:kind])}"

        assert is_binary(message.peer[:id]), "peer.id must be a binary"
        assert is_map(message.message), "InboundMessage.message must be a map"
        assert is_binary(message.message[:text]), "message.text must be a binary"

        # A message built from a real update has to be repliable; one salvaged
        # from a malformed update is only required to be well-typed.
        if routable? do
          assert message.peer[:id] != "",
                 "peer.id is empty — the platform cannot address a reply to this message"
        end
      end
    end
  end

  @doc """
  Starts `:lemon_channels` if it is not already running.

  The registration round-trip needs `LemonChannels.Registry` alive. Call this
  from your `test_helper.exs` instead if you prefer the application started once
  for the whole suite.
  """
  @spec ensure_channels_started!() :: :ok
  def ensure_channels_started! do
    case Application.ensure_all_started(:lemon_channels) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        raise """
        LemonPlatformTest.PluginCase needs the :lemon_channels application running
        to exercise the registry, but it failed to start: #{inspect(reason)}

        Start it in test_helper.exs, or pass `registry: false` to skip the
        registration round-trip.
        """
    end
  end
end
