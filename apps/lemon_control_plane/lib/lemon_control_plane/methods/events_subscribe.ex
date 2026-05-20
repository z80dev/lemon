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
    - `"goals"` - Durable goal lifecycle events
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
    "channels",
    "goals"
  ]

  @impl true
  def name, do: "events.subscribe"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    params = params || %{}
    topics = normalize_topics(params["topics"] || params[:topics] || ["all"])
    run_id = params["runId"] || params["run_id"] || params[:run_id]
    all_topics = topics ++ run_topics(run_id)

    invalid_topics = Enum.reject(all_topics, &valid_topic?/1)

    if length(invalid_topics) > 0 do
      {:error, Errors.invalid_request("Invalid topics: #{Enum.join(invalid_topics, ", ")}")}
    else
      EventBridge.subscribe_topics(all_topics)

      # Track subscription in connection state
      conn_id = ctx[:conn_id]
      conn_pid = ctx[:conn_pid]

      if present?(conn_id) or is_pid(conn_pid) do
        update_connection_subscriptions(conn_id, conn_pid, all_topics)
      end

      {:ok,
       %{
         "subscribed" => true,
         "topics" => all_topics,
         "runId" => run_id,
         "summary" => summary(all_topics, run_id, conn_id)
       }}
    end
  end

  defp valid_topic?(topic) when is_binary(topic) do
    topic in @allowed_topics ||
      String.starts_with?(topic, "run:") ||
      String.starts_with?(topic, "session:")
  end

  defp valid_topic?(_), do: false

  defp update_connection_subscriptions(_conn_id, conn_pid, topics) when is_pid(conn_pid) do
    send(conn_pid, {:subscribe_topics, topics})
    :ok
  end

  defp update_connection_subscriptions(conn_id, _conn_pid, topics) do
    case Process.whereis(LemonControlPlane.ConnectionRegistry) do
      nil ->
        :ok

      registry ->
        case Registry.lookup(registry, conn_id) do
          [{pid, _}] ->
            send(pid, {:subscribe_topics, topics})
            :ok

          [] ->
            :ok
        end
    end
  end

  defp normalize_topics(topics) when is_list(topics), do: topics
  defp normalize_topics(topic) when is_binary(topic), do: [topic]
  defp normalize_topics(_), do: ["all"]

  defp run_topics(run_id) when is_binary(run_id) and run_id != "", do: ["run:#{run_id}"]
  defp run_topics(_), do: []

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  defp summary(topics, run_id, conn_id) do
    %{
      "topicCount" => length(topics),
      "runSubscriptionCount" => Enum.count(topics, &String.starts_with?(&1, "run:")),
      "sessionSubscriptionCount" => Enum.count(topics, &String.starts_with?(&1, "session:")),
      "hasConnection" => is_binary(conn_id) and conn_id != "",
      "runId" => run_id,
      "cleanup" => %{
        "includesPayloads" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end
end
