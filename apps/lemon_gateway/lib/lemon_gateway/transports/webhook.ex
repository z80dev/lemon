defmodule LemonGateway.Transports.Webhook do
  @moduledoc """
  HTTP webhook transport for LemonGateway. Accepts prompt submissions via
  POST requests with support for synchronous and asynchronous response modes,
  callback delivery with retries, token-based authentication, and idempotency keys.

  This module is a thin orchestration layer that delegates to focused submodules:

  - `Webhook.Auth` — request verification and token authentication
  - `Webhook.Payload` — request normalization (prompt, attachments, metadata)
  - `Webhook.Routing` — integration config resolution, session key derivation
  - `Webhook.Callback` — callback delivery (sync waiting, async background, retries)
  - `Webhook.CallbackUrl` — callback URL validation and SSRF protection
  - `Webhook.Idempotency` — idempotency key tracking
  - `Webhook.Response` — reply shaping and request metadata
  - `Webhook.Helpers` — shared utility functions
  """

  use Plug.Router
  use LemonGateway.Transport

  require Logger

  alias LemonGateway.Runtime
  alias LemonGateway.Types.Job
  alias LemonCore.Id

  alias LemonGateway.Transports.Webhook.{
    Auth,
    Callback,
    CallbackUrl,
    Helpers,
    Idempotency,
    Payload,
    Response,
    Routing
  }

  @default_port if(Code.ensure_loaded?(Mix) and Mix.env() == :test, do: 0, else: 4046)

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
    if enabled?() do
      cfg = config()
      ip = bind_ip(cfg)
      port = Helpers.int_value(Helpers.fetch(cfg, :port), @default_port)

      Logger.info("Starting webhook transport server on #{inspect(ip)}:#{port}")

      Bandit.start_link(
        plug: __MODULE__,
        ip: ip,
        port: port,
        scheme: :http
      )
    else
      Logger.info("webhook transport disabled")
      :ignore
    end
  end

  post "/webhooks/:integration_id" do
    payload = Map.drop(conn.params || %{}, ["integration_id"])
    webhook_config = config()

    with %{} = integration <- integration_config(integration_id),
         :ok <- Auth.authorize_request(conn, payload, integration),
         {:ok, normalized} <- Payload.normalize(payload),
         {:ok, idempotency_ctx} <- Idempotency.context(conn, payload, integration_id, integration),
         {:ok, run_ctx} <-
           submit_run(conn, integration_id, integration, payload, normalized, idempotency_ctx, webhook_config),
         {:ok, status, response_payload} <- response_for_run(run_ctx) do
      Idempotency.store_response(idempotency_ctx, status, response_payload)
      Response.json(conn, status, response_payload)
    else
      nil ->
        Response.json_error(conn, 404, "integration not found")

      {:error, :unauthorized} ->
        Response.json_error(conn, 401, "unauthorized")

      {:error, :unprocessable_entity} ->
        Response.json_error(conn, 422, "invalid request payload")

      {:error, :invalid_callback_url} ->
        Response.json_error(conn, 422, "invalid callback url")

      {:error, :run_timeout} ->
        Response.json_error(conn, 500, "run timed out")

      {:duplicate, status, response_payload} ->
        Response.json(conn, status, response_payload)

      {:error, reason} ->
        Logger.warning("webhook transport request failed: #{inspect(reason)}")
        Response.json_error(conn, 500, "internal server error")
    end
  end

  match _ do
    Response.json_error(conn, 404, "not found")
  end

  @spec enabled?() :: boolean()
  def enabled? do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:enable_webhook) == true
    else
      fallback = Application.get_env(:lemon_gateway, :enable_webhook, false)
      (resolve_from_app_config(:enable_webhook) || fallback) == true
    end
  rescue
    _ -> false
  end

  @spec config() :: map()
  def config do
    cfg =
      if is_pid(Process.whereis(LemonGateway.Config)) do
        LemonGateway.Config.get(:webhook) || %{}
      else
        resolve_from_app_config(:webhook) || Application.get_env(:lemon_gateway, :webhook, %{})
      end

    Helpers.normalize_map(cfg)
  rescue
    _ -> %{}
  end

  # --- Test entry points (preserve existing test API) ---

  @doc false
  def normalize_payload_for_test(payload), do: Payload.normalize(payload)

  @doc false
  def secure_compare_for_test(expected, provided), do: Auth.secure_compare(expected, provided)

  @doc false
  def wait_for_run_completion_for_test(run_id, timeout_ms) do
    Callback.wait_for_run_completion(run_id, timeout_ms)
  end

  @doc false
  def callback_success_status_for_test(status), do: Callback.callback_success_status?(status)

  @doc false
  def validate_callback_url_for_test(callback_url, allow_private_hosts) do
    CallbackUrl.validate(callback_url, allow_private_hosts, [])
  end

  @doc false
  def validate_callback_url_for_test(callback_url, allow_private_hosts, opts)
      when is_list(opts) do
    CallbackUrl.validate(callback_url, allow_private_hosts, opts)
  end

  @doc false
  def request_metadata_for_test(conn), do: Response.request_metadata(conn)

  @doc false
  def resolve_callback_wait_timeout_ms_for_test(integration, webhook_config \\ %{}) do
    Routing.resolve_callback_wait_timeout_ms(integration, webhook_config)
  end

  @doc false
  def authorize_request_for_test(conn, payload, integration) do
    Auth.authorize_request(conn, payload, integration)
  end

  @doc false
  def idempotency_context_for_test(conn, payload, integration_id, integration) do
    Idempotency.context(conn, payload, integration_id, integration)
  end

  @doc false
  def idempotency_table_for_test, do: Idempotency.table()

  # --- Private orchestration ---

  defp response_for_run(%{mode: :sync} = run_ctx) do
    Callback.with_sync_subscription(run_ctx, fn ->
      case Callback.wait_for_run_completion(run_ctx.run_id, run_ctx.timeout_ms, subscribe?: false) do
        {:ok, run_payload} ->
          callback =
            Callback.maybe_send_callback(
              run_ctx.callback_url,
              Callback.callback_payload(run_ctx, run_payload),
              run_ctx.timeout_ms
            )

          payload =
            %{
              run_id: run_ctx.run_id,
              session_key: run_ctx.session_key,
              mode: "sync",
              completed: Callback.completed_payload(run_payload),
              duration_ms: Helpers.fetch(run_payload, :duration_ms)
            }
            |> Helpers.maybe_put(:callback, callback)

          {:ok, 200, payload}

        {:error, :timeout} ->
          {:error, :run_timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp response_for_run(run_ctx) do
    payload =
      %{
        run_id: run_ctx.run_id,
        session_key: run_ctx.session_key,
        mode: "async",
        status: "accepted"
      }
      |> Helpers.maybe_put(:callback, run_ctx.callback_status)

    {:ok, 202, payload}
  end

  defp submit_run(conn, integration_id, integration, payload, normalized, idempotency_ctx, webhook_config) do
    run_id = Id.run_id()
    session_key = Routing.resolve_session_key(integration)
    mode = Routing.resolve_mode(integration, webhook_config)
    timeout_ms = Routing.resolve_timeout_ms(integration, webhook_config)
    callback_wait_timeout_ms = Routing.resolve_callback_wait_timeout_ms(integration, webhook_config)
    queue_mode = Routing.resolve_queue_mode(integration)
    callback_retry = Routing.callback_retry_config(integration, webhook_config)
    allow_private_callback_hosts = Routing.allow_private_callback_hosts?(integration, webhook_config)

    with {:ok, callback_url} <-
           payload
           |> Routing.resolve_callback_url(integration, webhook_config)
           |> CallbackUrl.validate(allow_private_callback_hosts),
         {:ok, wait_setup, callback_status} <-
           Callback.prepare_wait_before_submit(mode, %{
             integration_id: integration_id,
             run_id: run_id,
             session_key: session_key,
             timeout_ms: timeout_ms,
             callback_wait_timeout_ms: callback_wait_timeout_ms,
             callback_url: callback_url,
             metadata: normalized.metadata,
             attachments: normalized.attachments,
             callback_retry: callback_retry
           }) do
      job =
        build_submit_job(
          conn,
          integration_id,
          integration,
          normalized,
          run_id,
          session_key,
          queue_mode,
          webhook_config
        )

      run_ctx = %{
        integration_id: integration_id,
        run_id: run_id,
        session_key: session_key,
        mode: mode,
        timeout_ms: timeout_ms,
        callback_wait_timeout_ms: callback_wait_timeout_ms,
        callback_url: callback_url,
        metadata: normalized.metadata,
        attachments: normalized.attachments,
        callback_retry: callback_retry,
        callback_status: callback_status
      }

      perform_submit(job, run_ctx, wait_setup, idempotency_ctx)
    end
  end

  defp build_submit_job(
         conn,
         integration_id,
         integration,
         normalized,
         run_id,
         session_key,
         queue_mode,
         webhook_config
       ) do
    %Job{
      run_id: run_id,
      session_key: session_key,
      prompt: normalized.prompt,
      engine_id: Routing.resolve_engine(integration),
      cwd: Helpers.normalize_blank(Helpers.fetch(integration, :cwd)),
      queue_mode: queue_mode,
      meta: %{
        origin: :webhook,
        webhook: %{
          integration_id: integration_id,
          metadata: normalized.metadata,
          attachments: normalized.attachments,
          request: Response.request_metadata(conn),
          integration: Routing.integration_metadata(integration, webhook_config)
        }
      }
    }
  end

  defp perform_submit(job, run_ctx, wait_setup, idempotency_ctx) do
    try do
      :ok = Runtime.submit(job)

      Idempotency.store_submission(
        idempotency_ctx,
        run_ctx.run_id,
        run_ctx.session_key,
        run_ctx.mode
      )

      {:ok, Map.merge(run_ctx, wait_setup)}
    rescue
      error ->
        Callback.cleanup_wait_setup(wait_setup)
        {:error, {:submit_failed, Exception.message(error)}}
    end
  end

  defp integration_config(integration_id) when is_binary(integration_id) do
    integrations = Helpers.fetch(config(), :integrations)

    if is_map(integrations) do
      Enum.find_value(integrations, fn {key, value} ->
        if to_string(key) == integration_id do
          Helpers.normalize_map(value)
        end
      end)
    else
      nil
    end
  end

  defp integration_config(_), do: nil

  defp bind_ip(cfg) do
    case Helpers.normalize_blank(Helpers.fetch(cfg, :bind)) do
      nil -> :loopback
      "127.0.0.1" -> :loopback
      "localhost" -> :loopback
      "0.0.0.0" -> :any
      "any" -> :any
      other -> parse_ip(other) || :loopback
    end
  end

  defp parse_ip(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  defp parse_ip(_), do: nil

  defp resolve_from_app_config(key) do
    cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

    cond do
      is_list(cfg) and Keyword.keyword?(cfg) -> Keyword.get(cfg, key)
      is_map(cfg) -> Helpers.fetch(cfg, key)
      true -> nil
    end
  end
end
