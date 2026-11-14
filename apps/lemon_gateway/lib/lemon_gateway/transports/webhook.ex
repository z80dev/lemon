defmodule LemonGateway.Transports.Webhook do
  @moduledoc """
  HTTP webhook transport for LemonGateway.
  """

  use Plug.Router
  use LemonGateway.Transport

  require Logger

  alias LemonCore.Id

  alias LemonGateway.Transports.Webhook.{
    Config,
    Idempotency,
    InvocationDispatch,
    Request,
    Response
  }

  @default_timeout_ms 30_000
  @default_callback_wait_timeout_ms 10 * 60 * 1000
  @callback_waiter_ready_timeout_ms 1_000

  plug(Plug.Logger, log: :debug)
  plug(LemonGateway.DrainGuard)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  @impl LemonGateway.Transport
  def id, do: "webhook"

  @impl LemonGateway.Transport
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @impl LemonGateway.Transport
  def start_link(_opts) do
    if Config.enabled?() do
      cfg = Config.config()
      ip = Config.bind_ip(cfg)
      port = Config.port(cfg)

      Logger.info("Starting webhook transport server on #{inspect(ip)}:#{port}")
      Bandit.start_link(plug: __MODULE__, ip: ip, port: port, scheme: :http)
    else
      Logger.info("webhook transport disabled")
      :ignore
    end
  end

  post "/webhooks/:integration_id" do
    payload = Map.drop(conn.params || %{}, ["integration_id"])

    with %{} = integration <- Config.integration_config(integration_id),
         :ok <- Request.authorize_request(conn, payload, integration, Config.config()),
         {:ok, normalized} <- Request.normalize_payload(payload),
         {:ok, idempotency_ctx} <-
           Idempotency.context(conn, payload, integration_id, integration, Config.config()),
         {:ok, run_ctx} <-
           InvocationDispatch.submit_run(
             conn,
             integration_id,
             integration,
             payload,
             normalized,
             idempotency_ctx,
             webhook_config: Config.config(),
             default_timeout_ms: @default_timeout_ms,
             default_callback_wait_timeout_ms: @default_callback_wait_timeout_ms,
             callback_waiter_ready_timeout_ms: @callback_waiter_ready_timeout_ms,
             run_id: idempotency_run_id(idempotency_ctx),
             validate_callback_url: &Request.validate_callback_url/3,
             request_metadata_fun: &Request.request_metadata/1
           ),
         {:ok, status, response_payload} <- Response.response_for_run(run_ctx, []),
         :ok <- Idempotency.store_response(idempotency_ctx, status, response_payload) do
      json(conn, status, response_payload)
    else
      nil ->
        json_error(conn, 404, "integration not found")

      {:error, :unauthorized} ->
        json_error(conn, 401, "unauthorized")

      {:error, :unprocessable_entity} ->
        json_error(conn, 422, "invalid request payload")

      {:error, :invalid_callback_url} ->
        json_error(conn, 422, "invalid callback url")

      {:error, :run_timeout} ->
        json_error(conn, 500, "run timed out")

      {:error, :idempotency_unavailable} ->
        json(conn, 503, %{error: "idempotency unavailable", retry_safe: true})

      {:error, :invalid_idempotency_key} ->
        json_error(conn, 422, "invalid idempotency key")

      {:duplicate, status, response_payload} ->
        json(conn, status, response_payload)

      {:error, reason} ->
        Logger.warning("webhook transport request failed: #{inspect(reason)}")
        json_error(conn, 500, "internal server error")
    end
  end

  match _ do
    json_error(conn, 404, "not found")
  end

  defp idempotency_run_id(%{run_id: run_id}) when is_binary(run_id), do: run_id
  defp idempotency_run_id(_idempotency_ctx), do: Id.run_id()

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp json_error(conn, status, message) do
    json(conn, status, %{error: message})
  end
end
