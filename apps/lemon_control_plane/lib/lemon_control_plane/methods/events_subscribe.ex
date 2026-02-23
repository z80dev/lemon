defmodule LemonControlPlane.Methods.EventsSubscribe do
  @moduledoc """
  Handler for the `events.subscribe` control-plane method.

  Subscribe an agent session to receive external events from the
  ingestion pipeline (Polymarket, Twitter, price feeds, etc.).

  ## Parameters

    * `sessionKey` - Required. The session to receive events
    * `type` - Required. Event type: "polymarket", "twitter", "price", "news"
    * `filters` - Optional. Source-specific filter criteria
    * `importance` - Optional. Minimum importance: "low", "medium", "high", "critical"

  ## Examples

      {
        "method": "events.subscribe",
        "params": {
          "sessionKey": "agent:zeebot:main",
          "type": "polymarket",
          "filters": {
            "min_liquidity": 100000,
            "min_trade_size": 10000
          },
          "importance": "medium"
        }
      }
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "events.subscribe"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, session_key} <- get_required_param(params, "sessionKey"),
         {:ok, type} <- get_required_param(params, "type"),
         {:ok, type_atom} <- parse_type(type),
         filters <- Map.get(params, "filters", %{}),
         importance <- parse_importance(Map.get(params, "importance", "low")),
         {:ok, agent_id} <- extract_agent_id(session_key),
         :ok <- ensure_ingestion_loaded(),
         :ok <- LemonIngestion.subscribe(session_key, %{
           type: type_atom,
           filters: filters,
           importance: importance,
           agent_id: agent_id
         }) do
      {:ok,
       %{
         "sessionKey" => session_key,
         "type" => type,
         "filters" => filters,
         "importance" => importance
       }}
    else
      {:error, :missing_param, name} ->
        {:error, {:invalid_request, "Missing required parameter: #{name}", nil}}

      {:error, :invalid_type, type} ->
        {:error, {:invalid_request, "Invalid event type: #{type}", nil}}

      {:error, :app_not_loaded} ->
        {:error, {:internal_error, "Ingestion service not available", nil}}

      {:error, reason} ->
        {:error, {:internal_error, "Failed to subscribe", inspect(reason)}}
    end
  end

  # --- Private Functions ---

  defp get_required_param(params, key) do
    case Map.get(params, key) || Map.get(params, Macro.underscore(key)) do
      nil -> {:error, :missing_param, key}
      "" -> {:error, :missing_param, key}
      value -> {:ok, value}
    end
  end

  defp parse_type("polymarket"), do: {:ok, :polymarket}
  defp parse_type("twitter"), do: {:ok, :twitter}
  defp parse_type("price"), do: {:ok, :price}
  defp parse_type("news"), do: {:ok, :news}
  defp parse_type(other), do: {:error, :invalid_type, other}

  defp parse_importance("critical"), do: :critical
  defp parse_importance("high"), do: :high
  defp parse_importance("medium"), do: :medium
  defp parse_importance("low"), do: :low
  defp parse_importance(other) when is_atom(other), do: other
  defp parse_importance(_), do: :low

  defp extract_agent_id(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id | _] -> {:ok, agent_id}
      _ -> {:ok, "unknown"}
    end
  end

  defp ensure_ingestion_loaded do
    if Code.ensure_loaded?(LemonIngestion) do
      :ok
    else
      {:error, :app_not_loaded}
    end
  end
end
