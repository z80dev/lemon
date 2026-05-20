defmodule LemonControlPlane.Methods.EventsUnsubscribe do
  @moduledoc """
  Unsubscribe from events stream.

  Allows clients to unsubscribe from specific event topics or all topics.

  ## Parameters

    - `topics` - List of topics to unsubscribe from (optional, defaults to all)
    - `runId` - Specific run ID to unsubscribe from (optional)

  ## Example

      {
        "method": "events.unsubscribe",
        "params": {
          "topics": ["run:abc123"]
        }
      }
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.EventBridge

  @impl true
  def name, do: "events.unsubscribe"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    params = params || %{}
    topics = normalize_topics(params["topics"] || params[:topics])
    run_id = params["runId"] || params["run_id"] || params[:run_id]
    all_topics = topics ++ run_topics(run_id)

    EventBridge.unsubscribe_topics(event_bridge_topics(all_topics, ctx))

    # Update connection subscriptions
    conn_id = ctx[:conn_id]
    conn_pid = ctx[:conn_pid]

    if present?(conn_id) or is_pid(conn_pid) do
      remove_connection_subscriptions(conn_id, conn_pid, unsubscribe_payload(all_topics))
    end

    {:ok,
     %{
       "unsubscribed" => true,
       "topics" => if(all_topics == [], do: nil, else: all_topics),
       "runId" => run_id,
       "summary" => summary(all_topics, run_id, conn_id)
     }}
  end

  defp remove_connection_subscriptions(_conn_id, conn_pid, topics) when is_pid(conn_pid) do
    send(conn_pid, {:unsubscribe_topics, topics})
    :ok
  end

  defp remove_connection_subscriptions(conn_id, _conn_pid, topics) do
    case Process.whereis(LemonControlPlane.ConnectionRegistry) do
      nil ->
        :ok

      registry ->
        case Registry.lookup(registry, conn_id) do
          [{pid, _}] ->
            send(pid, {:unsubscribe_topics, topics})
            :ok

          [] ->
            :ok
        end
    end
  end

  defp normalize_topics(nil), do: []
  defp normalize_topics(topics) when is_list(topics), do: Enum.filter(topics, &is_binary/1)
  defp normalize_topics(topic) when is_binary(topic), do: [topic]
  defp normalize_topics(_), do: []

  defp run_topics(run_id) when is_binary(run_id) and run_id != "", do: ["run:#{run_id}"]
  defp run_topics(_), do: []

  defp event_bridge_topics([], ctx) do
    case ctx[:subscriptions] do
      %MapSet{} = subscriptions -> MapSet.to_list(subscriptions)
      _ -> []
    end
  end

  defp event_bridge_topics(topics, _ctx), do: topics

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  defp unsubscribe_payload([]), do: :all
  defp unsubscribe_payload(topics), do: topics

  defp summary(topics, run_id, conn_id) do
    all? = topics == []

    %{
      "topicCount" => length(topics),
      "all" => all?,
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
