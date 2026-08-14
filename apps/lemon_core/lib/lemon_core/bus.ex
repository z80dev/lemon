defmodule LemonCore.Bus do
  @moduledoc """
  Process-safe PubSub for cross-app event communication.

  The Bus provides a simple publish/subscribe mechanism for broadcasting
  events across the Lemon umbrella apps.

  ## Topic Contract

  Platform-contract topics. Their payloads are typed by `LemonCore.Events`, and changing one
  after publication is a semver-major change:

  - `"run:<run_id>"` - Events for a specific run
  - `"session:<session_key>"` - Events for a specific session, including everything the
    router forwards from that session's run topics
  - `"cron"` - Cron/automation events
  - `"exec_approvals"` - Execution approval request/resolution events
  - `"system"` - System-wide events (config reload, secret changes, talk mode)
  - `"goals"` - Durable goal lifecycle events
  - `"routing_feedback"` - Finalized run feedback samples for router-owned model selection

  Topics whose publisher and every subscriber live in one app are *not* platform contract.
  They are listed here only so this is a complete map of what is on the bus: `"nodes"` and
  `"presence"` (lemon_control_plane), `"run_graph:<run_id>"` and
  `"parent_question:<request_id>"` (coding_agent), and `"sim:<id>"`, `"sim:<id>:decisions"`,
  `"sim:lobby"`, `"arena:<domain>:league"` plus the hosted-game and philosopher-chat topics
  (lemon_sim / lemon_sim_ui).

  `"channels"` and `"logs"` were listed here as stable topics until Phase 3.1, but no module
  has ever published to either. `"channels"` is reachable only through the control-plane
  event-injection methods; `"logs"` is reachable by nothing.

  The full catalog, including every publisher and subscriber, is in
  `docs/platform/bus-events.md` in the Lemon repository.

  ## Examples

      # Subscribe to run events
      LemonCore.Bus.subscribe("run:abc-123")

      # Receive events in the subscribing process
      receive do
        %LemonCore.Event{type: :delta, payload: payload} ->
          IO.puts("Received delta: \#{inspect(payload)}")
      end

      # Broadcast an event
      event = LemonCore.Event.new(:delta, %{text: "Hello"})
      LemonCore.Bus.broadcast("run:abc-123", event)

  ## Backends

  `phoenix_pubsub` is an optional dependency. When it is available (the case
  for the Lemon runtime, and for anything running Phoenix) the Bus is a thin
  wrapper over `Phoenix.PubSub` and broadcasts reach the whole cluster.

  When it is not, the Bus falls back to a `Registry` with duplicate keys,
  started by `LemonCore.Application` under the same supervision tree. The four
  operations behave identically **on the local node**; the fallback does not
  cross node boundaries. Distributed deployments should depend on
  `phoenix_pubsub` explicitly.

  """

  @pubsub LemonCore.PubSub
  @registry LemonCore.Bus.Registry

  @compile {:no_warn_undefined, Phoenix.PubSub}
  @backend_key {__MODULE__, :backend}
  @default_enforcement Mix.env() in [:dev, :test]

  @doc """
  Subscribe the calling process to a topic.

  Returns `:ok` on success.
  """
  @spec subscribe(topic :: binary()) :: :ok
  def subscribe(topic) when is_binary(topic) do
    if pubsub?() do
      Phoenix.PubSub.subscribe(@pubsub, topic)
    else
      case Registry.register(@registry, topic, nil) do
        {:ok, _owner} -> :ok
        {:error, {:already_registered, _pid}} -> :ok
      end
    end
  end

  @doc """
  Unsubscribe the calling process from a topic.

  Returns `:ok` on success.
  """
  @spec unsubscribe(topic :: binary()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    if pubsub?() do
      Phoenix.PubSub.unsubscribe(@pubsub, topic)
    else
      Registry.unregister(@registry, topic)
    end
  end

  @doc """
  Broadcast an event to all subscribers of a topic.

  The event can be a `LemonCore.Event` struct or any term.
  Returns `:ok` on success.
  """
  @spec broadcast(topic :: binary(), event :: LemonCore.Event.t() | term()) :: :ok
  def broadcast(topic, event) when is_binary(topic) do
    if pubsub?() do
      Phoenix.PubSub.broadcast(@pubsub, topic, event)
    else
      dispatch(topic, event, nil)
    end
  end

  @doc """
  Broadcast a typed event, checking the payload against `LemonCore.Events`.

  This is the publishing path for contract topics. When the event type is registered and the
  payload is not its struct, the mismatch raises in `:dev` and `:test` and is coerced in
  `:prod` — a malformed payload should fail a developer's test run, not a user's agent run.

      Bus.broadcast_event(Bus.run_topic(run_id), :run_started, %Events.RunStarted{...})

  Unregistered types are broadcast as-is, so app-internal topics can use this function too.
  """
  @spec broadcast_event(topic :: binary(), type :: atom(), payload :: term(), meta :: map() | nil) ::
          :ok
  def broadcast_event(topic, type, payload, meta \\ nil)
      when is_binary(topic) and is_atom(type) do
    broadcast(topic, LemonCore.Event.new(type, checked_payload!(type, payload), meta))
  end

  # Coercing rather than passing through is what the `:prod` branch owes consumers now that
  # `LemonCore.Events` payloads no longer implement `Access`: subscribers pattern-match the
  # struct, so relaying a legacy map untouched would drop the event at every one of them
  # instead of degrading it. A payload too malformed to coerce is still relayed as-is, for the
  # subscriber's own defensive handling to deal with.
  defp checked_payload!(type, payload) do
    module = LemonCore.Events.payload_module(type)

    cond do
      is_nil(module) -> payload
      is_struct(payload, module) -> payload
      not enforce_payloads?() -> LemonCore.Events.coerce(type, payload)
      true -> raise ArgumentError, payload_mismatch_message(type, module, payload)
    end
  end

  defp payload_mismatch_message(type, module, payload) do
    "#{inspect(type)} is a registered platform event; its payload must be a " <>
      "#{inspect(module)} struct, got: #{inspect(payload, limit: 5)}. " <>
      "Build it with #{inspect(module)}.new/1, or #{inspect(module)}.from_map/1 if you are " <>
      "relaying a legacy payload."
  end

  defp enforce_payloads? do
    Application.get_env(:lemon_core, :enforce_event_payloads, @default_enforcement)
  end

  @doc """
  Broadcast an event from the calling process (excluding self).
  """
  @spec broadcast_from(topic :: binary(), event :: LemonCore.Event.t() | term()) :: :ok
  def broadcast_from(topic, event) when is_binary(topic) do
    if pubsub?() do
      Phoenix.PubSub.broadcast_from(@pubsub, self(), topic, event)
    else
      dispatch(topic, event, self())
    end
  end

  @doc """
  Which backend is in use: `:pubsub` or `:registry`.

  Detected at runtime on first use and memoized, because `phoenix_pubsub` being
  compiled alongside lemon_core does not mean it is on the code path of every
  app that depends on lemon_core — optional dependencies are not inherited
  transitively. `config :lemon_core, :bus_backend, :registry` forces the
  fallback even where `Phoenix.PubSub` is available, which is how tests
  exercise it.
  """
  @spec backend() :: :pubsub | :registry
  def backend do
    case Application.get_env(:lemon_core, :bus_backend, :auto) do
      :registry -> :registry
      :pubsub -> :pubsub
      _auto -> :persistent_term.get(@backend_key, nil) || detect_backend()
    end
  end

  @doc "Whether `phoenix_pubsub` backs the Bus, as opposed to the Registry fallback."
  @spec pubsub?() :: boolean()
  def pubsub?, do: backend() == :pubsub

  @doc """
  Whether the active backend's process is running, so a broadcast would be delivered.

  Publishers that are optional about eventing (they emit only as a side effect of some
  other durable write) should gate on this rather than on `Process.whereis/1` of a
  particular backend — checking for `LemonCore.PubSub` specifically makes the publisher
  silently inert under the Registry fallback.
  """
  @spec running?() :: boolean()
  def running? do
    name = if pubsub?(), do: @pubsub, else: @registry
    is_pid(Process.whereis(name))
  end

  @doc false
  @spec child_spec_for_backend() :: Supervisor.child_spec() | {module(), keyword()}
  def child_spec_for_backend do
    case backend() do
      :pubsub -> {Phoenix.PubSub, name: @pubsub}
      :registry -> {Registry, keys: :duplicate, name: @registry}
    end
  end

  defp detect_backend do
    backend = if Code.ensure_loaded?(Phoenix.PubSub), do: :pubsub, else: :registry
    :persistent_term.put(@backend_key, backend)
    backend
  end

  defp dispatch(topic, event, except) do
    Registry.dispatch(@registry, topic, fn subscribers ->
      for {pid, _value} <- subscribers, pid != except, do: send(pid, event)
    end)
  end

  @doc """
  Build a run topic from a run_id.
  """
  @spec run_topic(run_id :: binary()) :: binary()
  def run_topic(run_id) when is_binary(run_id) do
    "run:#{run_id}"
  end

  @doc """
  Build a session topic from a session_key.
  """
  @spec session_topic(session_key :: binary()) :: binary()
  def session_topic(session_key) when is_binary(session_key) do
    "session:#{session_key}"
  end
end
