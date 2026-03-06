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
    RequestNormalization,
    ResponseBuilder,
    SignatureValidation,
    Submission
  }

  @default_timeout_ms 30_000
  @default_callback_wait_timeout_ms 10 * 60 * 1000
  @callback_waiter_ready_timeout_ms 1_000

  plug(Plug.Logger, log: :debug)

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
         :ok <- SignatureValidation.authorize_request(conn, payload, integration, Config.config()),
         {:ok, normalized} <- RequestNormalization.normalize_payload(payload),
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
             default_engine: Config.default_engine(),
             default_timeout_ms: @default_timeout_ms,
             default_callback_wait_timeout_ms: @default_callback_wait_timeout_ms,
             callback_waiter_ready_timeout_ms: @callback_waiter_ready_timeout_ms,
             run_id: Id.run_id(),
             validate_callback_url: &RequestNormalization.validate_callback_url/3,
             request_metadata_fun: &RequestNormalization.request_metadata/1
           ),
         {:ok, status, response_payload} <- ResponseBuilder.response_for_run(run_ctx, []) do
      Idempotency.store_response(idempotency_ctx, status, response_payload)
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

  @doc false
  def normalize_payload_for_test(payload), do: RequestNormalization.normalize_payload(payload)

  @doc false
  def secure_compare_for_test(expected, provided),
    do: RequestNormalization.secure_compare(expected, provided)

  @doc false
  def wait_for_run_completion_for_test(run_id, timeout_ms) do
    ResponseBuilder.wait_for_run_completion(run_id, timeout_ms)
  end

  @doc false
  def callback_success_status_for_test(status),
    do: ResponseBuilder.callback_success_status?(status)

  @doc false
  def validate_callback_url_for_test(callback_url, allow_private_hosts) do
    RequestNormalization.validate_callback_url(callback_url, allow_private_hosts, [])
  end

  @doc false
  def validate_callback_url_for_test(callback_url, allow_private_hosts, opts)
      when is_list(opts) do
    RequestNormalization.validate_callback_url(callback_url, allow_private_hosts, opts)
  end

  @doc false
  def request_metadata_for_test(conn), do: RequestNormalization.request_metadata(conn)

  @doc false
  def resolve_callback_wait_timeout_ms_for_test(integration, webhook_config \\ %{}) do
    Submission.resolve_callback_wait_timeout_ms(
      integration,
      webhook_config,
      @default_callback_wait_timeout_ms
    )
  end

  @doc false
  def authorize_request_for_test(conn, payload, integration) do
    SignatureValidation.authorize_request(conn, payload, integration, Config.config())
  end

  @doc false
  def idempotency_context_for_test(conn, payload, integration_id, integration) do
    Idempotency.context(conn, payload, integration_id, integration, Config.config())
  end

  @doc false
  def idempotency_table_for_test, do: Idempotency.table()

  defp json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp json_error(conn, status, message) do
    json(conn, status, %{error: message})
  end
end
