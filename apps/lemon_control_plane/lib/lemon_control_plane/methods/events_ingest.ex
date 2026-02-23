defmodule LemonControlPlane.Methods.EventsIngest do
  @moduledoc """
  Handler for the `events.ingest` control-plane method.

  Manually ingest an event into the pipeline. This is useful for
  testing or for external systems that want to push events directly
  rather than using the HTTP webhook endpoint.

  ## Parameters

    * `source` - Required. Event source: "polymarket", "twitter", "price", "news"
    * `type` - Required. Event type (source-specific)
    * `data` - Required. Event payload
    * `importance` - Optional. "low", "medium", "high", "critical"
    * `url` - Optional. Link to source

  ## Examples

      {
        "method": "events.ingest",
        "params": {
          "source": "polymarket",
          "type": "large_trade",
          "importance": "high",
          "data": {
            "market_id": "0xabc...",
            "market_title": "Will ETH hit $5000?",
            "trade_size": 50000,
            "liquidity": 2000000
          },
          "url": "https://polymarket.com/market/..."
        }
      }
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "events.ingest"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, source} <- get_required_param(params, "source"),
         {:ok, source_atom} <- parse_source(source),
         {:ok, type} <- get_required_param(params, "type"),
         {:ok, data} <- get_required_param(params, "data"),
         :ok <- ensure_ingestion_loaded() do
      event = %{
        id: params["id"] || generate_event_id(),
        source: source_atom,
        type: type,
        timestamp: DateTime.utc_now(),
        importance: parse_importance(params["importance"] || "medium"),
        data: data,
        url: params["url"]
      }

      case LemonIngestion.ingest(event) do
        {:ok, result} ->
          {:ok,
           %{
             "eventId" => event.id,
             "delivered" => result.delivered,
             "failed" => result.failed
           }}

        {:error, reason} ->
          {:error, {:internal_error, "Failed to ingest event", inspect(reason)}}
      end
    else
      {:error, :missing_param, name} ->
        {:error, {:invalid_request, "Missing required parameter: #{name}", nil}}

      {:error, :invalid_source, source} ->
        {:error, {:invalid_request, "Invalid source: #{source}", nil}}

      {:error, :app_not_loaded} ->
        {:error, {:internal_error, "Ingestion service not available", nil}}
    end
  end

  # --- Private Functions ---

  defp get_required_param(params, key) do
    case Map.get(params, key) || Map.get(params, Macro.underscore(key)) do
      nil -> {:error, :missing_param, key}
      value -> {:ok, value}
    end
  end

  defp parse_source("polymarket"), do: {:ok, :polymarket}
  defp parse_source("twitter"), do: {:ok, :twitter}
  defp parse_source("price"), do: {:ok, :price}
  defp parse_source("news"), do: {:ok, :news}
  defp parse_source(other), do: {:error, :invalid_source, other}

  defp parse_importance("critical"), do: :critical
  defp parse_importance("high"), do: :high
  defp parse_importance("medium"), do: :medium
  defp parse_importance("low"), do: :low
  defp parse_importance(other) when is_atom(other), do: other
  defp parse_importance(_), do: :medium

  defp ensure_ingestion_loaded do
    if Code.ensure_loaded?(LemonIngestion) do
      :ok
    else
      {:error, :app_not_loaded}
    end
  end

  defp generate_event_id do
    "evt_#{System.unique_integer([:positive])}_#{:erlang.monotonic_time()}"
  end
end
