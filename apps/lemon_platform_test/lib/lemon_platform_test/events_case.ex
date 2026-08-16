# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
# This is an ExUnit CaseTemplate: the `using/1` quote block is intentionally
# large because it injects the entire compliance suite into the including test
# module. Splitting it would obscure the contract it exists to express.
defmodule LemonPlatformTest.EventsCase do
  @moduledoc """
  Contract suite for typed bus payloads (`LemonCore.Events.*`).

  Run it against the platform's own registry, or against your extension's payload modules
  if you publish your own events onto `LemonCore.Bus`:

      defmodule MyApp.EventsContractTest do
        use LemonPlatformTest.EventsCase, modules: [MyApp.Events.ThingHappened]
      end

  With no `:modules` option it exercises everything in `LemonCore.Events.modules/0`.

  ## What it asserts

  1. **Registry completeness** — every registered type resolves to a loaded module that
     exports the payload callbacks.
  2. **Round-trip** — `struct |> Map.from_struct() |> from_map()` returns the struct, which
     is what makes the legacy-map acceptance path honest rather than lossy.
  3. **String keys** — `from_map/1` accepts the string-keyed form that arrives from the
     control-plane event methods.
  4. **Unknown keys** — `new/1` rejects them (publisher-side typo protection) and
     `from_map/1` drops them (consumer-side tolerance).
  5. **Introspection compatibility** — a struct payload sanitizes to the same map its
     untyped predecessor did, so `Introspection.record/3` needs no per-event handling.
  6. **JSON encodability** — payloads survive `Jason.encode/1`, which the JSONL store
     backend and the control plane both require.
  7. **Envelope discipline and backend parity** — publishing through
     `LemonCore.Bus.broadcast_event/4` delivers a `%LemonCore.Event{}` carrying the struct
     intact, asserted under **both** bus backends. Publishers that check for a specific
     backend process rather than using the Bus API are inert under the Registry fallback;
     running every delivery assertion twice is what catches that.
  8. **No `Access`** — payload modules must not implement `Access`. The shim that let
     publishers migrate ahead of their consumers is gone; reading a payload by key hides the
     field rename that pattern matching catches at compile time.

  ## Example values

  Payload modules with enforced keys need a sample to test. Supply them with
  `:examples` when the defaults cannot be inferred:

      use LemonPlatformTest.EventsCase,
        modules: [MyApp.Events.ThingHappened],
        examples: %{MyApp.Events.ThingHappened => %{thing_id: "t_1"}}

  ## See also

  `LemonPlatformTest.EventsFixtures` builds valid typed payloads (with defaults and
  overrides) for use in *other* tests that publish onto the bus — the fixture companion
  to this contract suite.
  """

  use ExUnit.CaseTemplate

  using opts do
    LemonPlatformTest.require_dep!("EventsCase", LemonCore.Events, :lemon_core)

    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      import LemonPlatformTest.EventsCase

      @events_modules Keyword.get(opts, :modules) || LemonCore.Events.modules()
      @events_examples Keyword.get(opts, :examples, %{})

      test "every registered event type resolves to a payload module" do
        for {type, module} <- LemonCore.Events.registry() do
          assert Code.ensure_loaded?(module),
                 "#{inspect(type)} maps to #{inspect(module)}, which is not loadable"

          assert function_exported?(module, :new, 1),
                 "#{inspect(module)} must export new/1"

          assert function_exported?(module, :from_map, 1),
                 "#{inspect(module)} must export from_map/1"

          assert function_exported?(module, :event_version, 0),
                 "#{inspect(module)} must export event_version/0"
        end
      end

      test "payloads round-trip through from_map/1" do
        for module <- @events_modules do
          payload = LemonPlatformTest.EventsCase.example(module, @events_examples)

          assert module.from_map(Map.from_struct(payload)) == payload,
                 "#{inspect(module)} does not round-trip through from_map/1"

          assert module.from_map(payload) == payload,
                 "#{inspect(module)}.from_map/1 must pass its own struct through"
        end
      end

      test "from_map/1 coerces nested payloads, not just top-level fields" do
        # A payload arriving from JSON has plain maps all the way down. If `from_map/1` only
        # coerces the top level, a nested field stays a raw map and every consumer that
        # pattern-matches the nested struct silently stops matching.
        for module <- @events_modules do
          payload = LemonPlatformTest.EventsCase.example(module, @events_examples)
          flattened = LemonPlatformTest.EventsCase.to_plain_maps(payload)

          assert module.from_map(flattened) == payload,
                 "#{inspect(module)}.from_map/1 left a nested payload uncoerced"
        end
      end

      test "from_map/1 preserves false values" do
        # The trap: `Map.get(attrs, :key) || Map.get(attrs, "key")` reads atom-or-string keys
        # correctly for everything except `false`, which it turns into nil. On an engine
        # action that silently drops `ok: false` — the flag that says the action failed.
        for module <- @events_modules do
          payload = LemonPlatformTest.EventsCase.example(module, @events_examples)
          falsified = LemonPlatformTest.EventsCase.falsify_booleans(payload)

          assert module.from_map(LemonPlatformTest.EventsCase.to_plain_maps(falsified)) ==
                   falsified,
                 "#{inspect(module)}.from_map/1 does not round-trip false values"
        end
      end

      test "from_map/1 accepts string keys" do
        for module <- @events_modules do
          payload = LemonPlatformTest.EventsCase.example(module, @events_examples)

          stringified =
            payload
            |> Map.from_struct()
            |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

          assert module.from_map(stringified) == payload,
                 "#{inspect(module)}.from_map/1 must accept string keys"
        end
      end

      test "new/1 rejects unknown keys and from_map/1 drops them" do
        for module <- @events_modules do
          payload = LemonPlatformTest.EventsCase.example(module, @events_examples)
          attrs = Map.from_struct(payload)
          polluted = Map.put(attrs, :definitely_not_a_field, true)

          assert_raise ArgumentError, fn -> module.new(polluted) end

          assert module.from_map(polluted) == payload,
                 "#{inspect(module)}.from_map/1 must drop unknown keys"
        end
      end

      test "payloads sanitize for introspection exactly as their untyped form did" do
        for module <- @events_modules do
          payload = LemonPlatformTest.EventsCase.example(module, @events_examples)

          assert {:ok, typed} =
                   LemonCore.Introspection.build_event(module.event_type(), payload, [])

          assert {:ok, untyped} =
                   LemonCore.Introspection.build_event(
                     module.event_type(),
                     Map.from_struct(payload),
                     []
                   )

          assert typed.payload == untyped.payload,
                 "#{inspect(module)} sanitizes differently as a struct than as a map"
        end
      end

      test "payloads are JSON encodable" do
        for module <- @events_modules do
          payload = LemonPlatformTest.EventsCase.example(module, @events_examples)

          assert {:ok, _json} = Jason.encode(payload),
                 "#{inspect(module)} is not JSON encodable; the JSONL store backend needs it"
        end
      end

      test "payload modules do not implement Access" do
        for module <- @events_modules do
          refute LemonPlatformTest.EventsCase.implements_access?(module),
                 "#{inspect(module)} implements Access. Event payloads are pattern-matched or " <>
                   "read by field; a consumer holding a payload that may still be a legacy " <>
                   "map coerces it once with LemonCore.Events.coerce/2"
        end
      end

      for backend <- [:pubsub, :registry] do
        @backend backend

        test "broadcast_event/4 delivers the struct intact (#{backend} backend)" do
          LemonPlatformTest.EventsCase.with_backend(@backend, fn ->
            for module <- @events_modules, LemonCore.Events.registered?(module.event_type()) do
              type = module.event_type()
              payload = LemonPlatformTest.EventsCase.example(module, @events_examples)
              topic = "events_case:#{type}:#{System.unique_integer([:positive])}"

              :ok = LemonCore.Bus.subscribe(topic)
              :ok = LemonCore.Bus.broadcast_event(topic, type, payload, %{run_id: "run_test"})

              assert_receive %LemonCore.Event{type: ^type, payload: received, meta: meta}, 1_000

              assert received == payload,
                     "#{inspect(module)} did not survive the #{@backend} backend intact"

              assert meta.run_id == "run_test"

              :ok = LemonCore.Bus.unsubscribe(topic)
            end
          end)
        end

        test "broadcast_event/4 rejects a mismatched payload (#{backend} backend)" do
          LemonPlatformTest.EventsCase.with_backend(@backend, fn ->
            for {type, _module} <- Enum.take(LemonCore.Events.registry(), 3) do
              assert_raise ArgumentError, fn ->
                LemonCore.Bus.broadcast_event("events_case:mismatch", type, %{bogus: true})
              end
            end
          end)
        end
      end
    end
  end

  @doc """
  Build a sample payload for a module, from `examples` or by filling enforced keys.
  """
  @spec example(module(), %{optional(module()) => map()}) :: struct()
  def example(module, examples) do
    case Map.fetch(examples, module) do
      {:ok, %^module{} = payload} -> payload
      {:ok, attrs} -> module.new(attrs)
      :error -> module.new(default_attrs(module))
    end
  end

  @doc """
  Strip every struct out of a payload, recursively, leaving plain maps.

  Approximates what a payload looks like after a JSON round-trip, which is how one arrives
  from the control-plane event methods or an external agent.
  """
  @spec to_plain_maps(term()) :: term()
  def to_plain_maps(%_{} = struct) do
    struct |> Map.from_struct() |> to_plain_maps()
  end

  def to_plain_maps(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, to_plain_maps(value)} end)
  end

  def to_plain_maps(list) when is_list(list), do: Enum.map(list, &to_plain_maps/1)
  def to_plain_maps(value), do: value

  @doc """
  Replace every `true` in a payload with `false`, recursively, leaving other values alone.
  """
  @spec falsify_booleans(term()) :: term()
  def falsify_booleans(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {key, falsify_booleans(value)} end)
    |> then(&struct(module, &1))
  end

  def falsify_booleans(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, falsify_booleans(value)} end)
  end

  def falsify_booleans(true), do: false
  def falsify_booleans(value), do: value

  @doc """
  Run `fun` with the bus forced onto a specific backend, restoring the previous setting.

  The Registry fallback is a supported deployment (see `LemonCore.Bus`), so contract
  assertions have to hold under it too.
  """
  @spec with_backend(:pubsub | :registry, (-> any())) :: any()
  def with_backend(backend, fun) do
    previous = Application.get_env(:lemon_core, :bus_backend)
    Application.put_env(:lemon_core, :bus_backend, backend)

    try do
      if LemonCore.Bus.running?() do
        fun.()
      else
        # The backend's process is not running in this test environment; skipping is
        # honest, whereas asserting delivery would test nothing.
        :ok
      end
    after
      if is_nil(previous) do
        Application.delete_env(:lemon_core, :bus_backend)
      else
        Application.put_env(:lemon_core, :bus_backend, previous)
      end
    end
  end

  @doc """
  Whether a module implements the `Access` callbacks.

  Payloads carried an `Access` shim for one release cycle so that each publisher could migrate
  independently of its consumers. It is gone: reading a payload by key silently tolerates the
  field rename that a struct pattern turns into a compile error, and it is why
  `LemonControlPlane.EventBridge` could map events it no longer understood.
  """
  @spec implements_access?(module()) :: boolean()
  def implements_access?(module) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, :fetch, 2) or
         function_exported?(module, :get_and_update, 3) or
         function_exported?(module, :pop, 2))
  end

  defp default_attrs(module) do
    module
    |> enforced_keys()
    |> Map.new(fn key -> {key, sample_value(module, key)} end)
  end

  defp enforced_keys(module) do
    module.__info__(:struct)
    |> Enum.filter(& &1.required)
    |> Enum.map(& &1.field)
  end

  defp sample_value(LemonCore.Events.Action, :kind), do: :tool
  defp sample_value(LemonCore.Events.ChannelDelivery, :kind), do: :final_text
  defp sample_value(LemonCore.Events.ApprovalResolved, :decision), do: :deny
  defp sample_value(LemonCore.Events.CronJobChanged, :action), do: :created
  defp sample_value(LemonCore.Events.RunPhaseChanged, :phase), do: :running
  defp sample_value(LemonCore.Events.RunPhaseChanged, :source), do: :lemon_platform_test
  defp sample_value(LemonCore.Events.SecretChanged, :action), do: :put
  defp sample_value(LemonCore.Events.RoutingFeedback, :outcome), do: :success
  defp sample_value(LemonCore.Events.RunCompleted, :completed), do: completion_example()
  defp sample_value(LemonCore.Events.ApprovalRequested, :pending), do: approval_pending_example()
  defp sample_value(LemonCore.Events.EngineAction, :action), do: action_example()
  defp sample_value(_module, :ok), do: true
  defp sample_value(_module, :seq), do: 1
  defp sample_value(_module, :timestamp_ms), do: 1_754_800_000_000
  defp sample_value(_module, :audit), do: %{action: "created"}
  defp sample_value(_module, :reason), do: :example_reason
  defp sample_value(_module, key), do: "example_#{key}"

  defp completion_example, do: LemonCore.Events.Completion.new(%{ok: true, answer: "hi"})

  defp action_example do
    LemonCore.Events.Action.new(%{id: "act_1", kind: :tool, title: "Example"})
  end

  defp approval_pending_example do
    LemonCore.Events.ApprovalPending.new(%{id: "appr_1", tool: "bash"})
  end
end
