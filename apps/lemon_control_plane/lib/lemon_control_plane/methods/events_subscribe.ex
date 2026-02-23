defmodule LemonControlPlane.Methods.EventsSubscribe do
  @moduledoc """
  Subscribe to events stream.

  Allows clients to subscribe to specific event topics via WebSocket.
  Subscriptions are per-connection and managed by the EventBridge.

  ## Parameters

    - `topics` - List of topics to subscribe to (optional, defaults to ["all"])
    - `runId` - Specific run ID to subscribe to (optional)

  ## Topics

    - `"all"` - All events (default)
    - `"run:" <> run_id` - Events for a specific run
    - `"system"` - System events
    - `"cron"` - Cron job events
    - `"nodes"` - Node events
    - `"presence"` - Presence events
    - `"exec_approvals"` - Approval events

  ## Example

      {
        "method": "events.subscribe",
        "params": {
          "topics": ["run:abc123", "system"]
        }
      }
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.{EventBridge, Protocol.Errors}

  @allowed_topics [
    "all",
    "system",
    "cron",
    "nodes",
    "presence",
    "exec_approvals",
    "channels"
  ]

  @impl true
  def name, do: "events.subscribe"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    topics = params["topics"] || ["all"]
    run_id = params["runId"] || params["run_id"]

    # Validate topics
    invalid_topics = Enum.reject(topics, &valid_topic?/1)

    if length(invalid_topics) > 0 do
      {:error, Errors.invalid_request("Invalid topics: #{Enum.join(invalid_topics, ", ")}")}
    else
      # Subscribe to run events if run_id specified
      if run_id do
        EventBridge.subscribe_run(run_id)
      end

      # Track subscription in connection state
      conn_id = ctx[:conn_id]
      if conn_id do
        update_connection_subscriptions(conn_id, topics)
      end

      {:ok, %{
        "subscribed" => true,
        "topics" => topics,
        "runId" => run_id
      }}
    end
  end

  defp valid_topic?(topic) when is_binary(topic) do
    topic in @allowed_topics ||
      String.starts_with?(topic, "run:") ||
      String.starts_with?(topic, "session:")
  end

  defp valid_topic?(_), do: false

  defp update_connection_subscriptions(conn_id, topics) do
    # Update the connection's subscription list in the connection process
    # This is handled by the WebSocket connection process
    case Process.whereis(LemonControlPlane.WS.ConnectionRegistry) do
      nil -> :ok
      registry ->
        case Registry.lookup(registry, conn_id) do
          [{pid, _}] ->
            send(pid, {:subscribe_topics, topics})
            :ok
          [] -> :ok
        end
    end
  end
end
