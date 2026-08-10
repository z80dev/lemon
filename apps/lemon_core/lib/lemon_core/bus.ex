defmodule LemonCore.Bus do
  @moduledoc """
  Process-safe PubSub for cross-app event communication.

  The Bus provides a simple publish/subscribe mechanism for broadcasting
  events across the Lemon umbrella apps.

  ## Topic Contract

  Standard topics (must be stable):

  - `"run:<run_id>"` - Events for a specific run
  - `"session:<session_key>"` - Events for a specific session
  - `"channels"` - Channel-related events
  - `"cron"` - Cron/automation events
  - `"exec_approvals"` - Execution approval events
  - `"nodes"` - Node pairing/invoke events
  - `"routing_feedback"` - Finalized run feedback samples for router-owned model selection
  - `"system"` - System-wide events
  - `"logs"` - Log events

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
