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

  alias LemonControlPlane.{EventBridge, Protocol.Errors}

  @impl true
  def name, do: "events.unsubscribe"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    topics = params["topics"]
    run_id = params["runId"] || params["run_id"]

    # Unsubscribe from run events if run_id specified
    if run_id do
      EventBridge.unsubscribe_run(run_id)
    end

    # Update connection subscriptions
    conn_id = ctx[:conn_id]
    if conn_id && topics do
      remove_connection_subscriptions(conn_id, topics)
    end

    {:ok, %{
      "unsubscribed" => true,
      "topics" => topics,
      "runId" => run_id
    }}
  end

  defp remove_connection_subscriptions(conn_id, topics) do
    case Process.whereis(LemonControlPlane.WS.ConnectionRegistry) do
      nil -> :ok
      registry ->
        case Registry.lookup(registry, conn_id) do
          [{pid, _}] ->
            send(pid, {:unsubscribe_topics, topics})
            :ok
          [] -> :ok
        end
    end
  end
end
