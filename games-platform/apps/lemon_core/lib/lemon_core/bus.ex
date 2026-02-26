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

  """

  @pubsub LemonCore.PubSub

  @doc """
  Subscribe the calling process to a topic.

  Returns `:ok` on success.
  """
  @spec subscribe(topic :: binary()) :: :ok
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @doc """
  Unsubscribe the calling process from a topic.

  Returns `:ok` on success.
  """
  @spec unsubscribe(topic :: binary()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  @doc """
  Broadcast an event to all subscribers of a topic.

  The event can be a `LemonCore.Event` struct or any term.
  Returns `:ok` on success.
  """
  @spec broadcast(topic :: binary(), event :: LemonCore.Event.t() | term()) :: :ok
  def broadcast(topic, event) when is_binary(topic) do
    Phoenix.PubSub.broadcast(@pubsub, topic, event)
  end

  @doc """
  Broadcast an event from the calling process (excluding self).
  """
  @spec broadcast_from(topic :: binary(), event :: LemonCore.Event.t() | term()) :: :ok
  def broadcast_from(topic, event) when is_binary(topic) do
    Phoenix.PubSub.broadcast_from(@pubsub, self(), topic, event)
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
