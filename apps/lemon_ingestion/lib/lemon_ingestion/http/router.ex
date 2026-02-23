defmodule LemonIngestion.HTTP.Router do
  @moduledoc """
  HTTP router for the ingestion API.

  Provides endpoints for:
  - Receiving events from external sources (webhooks)
  - Managing subscriptions
  - Health checks

  ## Endpoints

  POST /v1/events/ingest
    Receive an event from an external source.
    Body: { "source": "polymarket", "type": "large_trade", "data": {...} }

  POST /v1/subscriptions
    Subscribe a session to events.
    Body: { "session_key": "agent:zeebot:main", "type": "polymarket", "filters": {...} }

  DELETE /v1/subscriptions/:session_key
    Unsubscribe a session.

  GET /v1/subscriptions
    List all subscriptions.

  GET /healthz
    Health check endpoint.
  """

  use Plug.Router

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  alias LemonIngestion.{Registry, Router}

  # Health check
  get "/healthz" do
    send_json(conn, 200, %{ok: true, service: "lemon_ingestion"})
  end

  # Ingest an event (webhook endpoint)
  post "/v1/events/ingest" do
    event = parse_event(conn.body_params)

    case Router.route(event) do
      {:ok, result} ->
        send_json(conn, 200, %{
          success: true,
          delivered: result.delivered,
          failed: result.failed
        })

      {:error, reason} ->
        send_json(conn, 400, %{success: false, error: inspect(reason)})
    end
  end

  # Create a subscription
  post "/v1/subscriptions" do
    with {:ok, session_key} <- get_required_param(conn.body_params, "session_key"),
         {:ok, type} <- get_required_param(conn.body_params, "type"),
         {:ok, type_atom} <- parse_type(type),
         filters <- Map.get(conn.body_params, "filters", %{}),
         importance <- parse_importance(Map.get(conn.body_params, "importance", "low")),
         :ok <- Registry.subscribe(session_key, %{
           type: type_atom,
           filters: filters,
           importance: importance
         }) do
      send_json(conn, 201, %{
        success: true,
        session_key: session_key,
        type: type,
        filters: filters
      })
    else
      {:error, :missing_param, name} ->
        send_json(conn, 400, %{success: false, error: "Missing required parameter: #{name}"})

      {:error, :invalid_type, type} ->
        send_json(conn, 400, %{success: false, error: "Invalid event type: #{type}"})

      {:error, reason} ->
        send_json(conn, 500, %{success: false, error: inspect(reason)})
    end
  end

  # Delete a subscription
  delete "/v1/subscriptions/:session_key" do
    Registry.unsubscribe(session_key)
    send_json(conn, 200, %{success: true, message: "Unsubscribed #{session_key}"})
  end

  # List all subscriptions
  get "/v1/subscriptions" do
    subscriptions =
      Registry.list_subscriptions()
      |> Enum.map(fn sub ->
        %{
          session_key: sub.session_key,
          agent_id: sub.agent_id,
          type: sub.type,
          filters: sub.filters,
          importance: sub.importance,
          created_at: sub.created_at
        }
      end)

    send_json(conn, 200, %{subscriptions: subscriptions, count: length(subscriptions)})
  end

  # Get adapter status
  get "/v1/adapters/status" do
    status = LemonIngestion.adapter_status()
    send_json(conn, 200, %{adapters: status})
  end

  # 404 fallback
  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  # --- Private Functions ---

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp parse_event(params) do
    %{
      id: params["id"] || generate_event_id(),
      source: parse_source(params["source"]),
      type: params["type"] |> to_string() |> String.to_existing_atom(),
      timestamp: parse_timestamp(params["timestamp"]),
      importance: parse_importance(params["importance"] || "medium"),
      data: params["data"] || %{},
      url: params["url"]
    }
  end

  defp parse_source("polymarket"), do: :polymarket
  defp parse_source("twitter"), do: :twitter
  defp parse_source("price"), do: :price
  defp parse_source("news"), do: :news
  defp parse_source(other) when is_binary(other), do: String.to_atom(other)
  defp parse_source(other), do: other

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts), do: DateTime.from_iso8601(ts) |> elem(1)
  defp parse_timestamp(ts), do: ts

  defp parse_importance("critical"), do: :critical
  defp parse_importance("high"), do: :high
  defp parse_importance("medium"), do: :medium
  defp parse_importance("low"), do: :low
  defp parse_importance(other) when is_atom(other), do: other
  defp parse_importance(_), do: :low

  defp parse_type("polymarket"), do: {:ok, :polymarket}
  defp parse_type("twitter"), do: {:ok, :twitter}
  defp parse_type("price"), do: {:ok, :price}
  defp parse_type("news"), do: {:ok, :news}
  defp parse_type(other), do: {:error, :invalid_type, other}

  defp get_required_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, :missing_param, key}
      "" -> {:error, :missing_param, key}
      value -> {:ok, value}
    end
  end

  defp generate_event_id do
    "evt_#{System.unique_integer([:positive])}_#{:erlang.monotonic_time()}"
  end
end
