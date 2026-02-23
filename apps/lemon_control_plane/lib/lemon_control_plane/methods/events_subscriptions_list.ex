defmodule LemonControlPlane.Methods.EventsSubscriptionsList do
  @moduledoc """
  Handler for the `events.subscriptions.list` control-plane method.

  List all active event subscriptions.

  ## Parameters

    * `agentId` - Optional. Filter by agent ID
    * `type` - Optional. Filter by event type

  ## Examples

      {
        "method": "events.subscriptions.list",
        "params": {
          "agentId": "zeebot"
        }
      }
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "events.subscriptions.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with :ok <- ensure_ingestion_loaded() do
      subscriptions =
        LemonIngestion.list_subscriptions()
        |> filter_by_agent(params["agentId"])
        |> filter_by_type(params["type"])
        |> Enum.map(fn sub ->
          %{
            "sessionKey" => sub.session_key,
            "agentId" => sub.agent_id,
            "type" => sub.type,
            "filters" => sub.filters,
            "importance" => sub.importance,
            "createdAt" => DateTime.to_iso8601(sub.created_at)
          }
        end)

      {:ok, %{"subscriptions" => subscriptions, "count" => length(subscriptions)}}
    else
      {:error, :app_not_loaded} ->
        {:error, {:internal_error, "Ingestion service not available", nil}}
    end
  end

  # --- Private Functions ---

  defp filter_by_agent(subscriptions, nil), do: subscriptions
  defp filter_by_agent(subscriptions, ""), do: subscriptions
  defp filter_by_agent(subscriptions, agent_id) do
    Enum.filter(subscriptions, fn sub -> sub.agent_id == agent_id end)
  end

  defp filter_by_type(subscriptions, nil), do: subscriptions
  defp filter_by_type(subscriptions, ""), do: subscriptions
  defp filter_by_type(subscriptions, type) do
    type_atom = String.to_existing_atom(type)
    Enum.filter(subscriptions, fn sub -> sub.type == type_atom end)
  end

  defp ensure_ingestion_loaded do
    if Code.ensure_loaded?(LemonIngestion) do
      :ok
    else
      {:error, :app_not_loaded}
    end
  end
end
