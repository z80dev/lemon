defmodule LemonGateway.Transports.Webhook.Submission do
  @moduledoc """
  Run-context assembly and router-facing run request construction for the webhook transport.
  """

  alias LemonGateway.Transports.Webhook.Request
  alias LemonCore.{RunRequest, SessionKey}

  @default_callback_max_attempts 3
  @default_callback_backoff_ms 500
  @default_callback_backoff_max_ms 5_000

  @type built_submission :: %{
          run_request: RunRequest.t(),
          run_ctx: map()
        }

  @spec build_submission(
          Plug.Conn.t(),
          binary(),
          map(),
          map(),
          %{prompt: binary(), attachments: list(), metadata: map()},
          keyword()
        ) :: {:ok, built_submission()} | {:error, :invalid_callback_url}
  def build_submission(conn, integration_id, integration, payload, normalized, opts)
      when is_binary(integration_id) and is_map(integration) and is_map(payload) and
             is_map(normalized) do
    webhook_config = Keyword.get(opts, :webhook_config, %{})
    validate_callback_url = Keyword.fetch!(opts, :validate_callback_url)
    request_metadata_fun = Keyword.fetch!(opts, :request_metadata_fun)
    default_engine = Keyword.get(opts, :default_engine, "lemon")
    default_callback_wait_timeout_ms = Keyword.fetch!(opts, :default_callback_wait_timeout_ms)
    run_id = Keyword.fetch!(opts, :run_id)

    session_key = resolve_session_key(integration)
    mode = resolve_mode(integration, webhook_config)

    timeout_ms =
      resolve_timeout_ms(integration, webhook_config, Keyword.fetch!(opts, :default_timeout_ms))

    callback_wait_timeout_ms =
      Request.resolve_callback_wait_timeout_ms(
        integration,
        webhook_config,
        default_callback_wait_timeout_ms
      )

    callback_retry = callback_retry_config(integration, webhook_config)
    allow_private_callback_hosts = allow_private_callback_hosts?(integration, webhook_config)

    with {:ok, callback_url} <-
           payload
           |> Request.resolve_callback_url(integration, webhook_config)
           |> validate_callback_url.(allow_private_callback_hosts, []) do
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
        callback_retry: callback_retry
      }

      run_request =
        RunRequest.new(%{
          origin: :webhook,
          run_id: run_id,
          session_key: session_key,
          agent_id: Request.normalize_blank(Request.fetch(integration, :agent_id)),
          prompt: normalized.prompt,
          queue_mode: resolve_queue_mode(integration),
          engine_id: resolve_engine(integration, default_engine),
          cwd: Request.normalize_blank(Request.fetch(integration, :cwd)),
          meta: %{
            webhook: %{
              integration_id: integration_id,
              metadata: normalized.metadata,
              attachments: normalized.attachments,
              request: request_metadata_fun.(conn),
              integration: integration_metadata(integration, webhook_config, default_engine)
            }
          }
        })

      {:ok, %{run_request: run_request, run_ctx: run_ctx}}
    end
  end

  @spec resolve_callback_wait_timeout_ms(map(), map(), pos_integer()) :: pos_integer()
  def resolve_callback_wait_timeout_ms(integration, webhook_config, default_timeout_ms) do
    Request.resolve_callback_wait_timeout_ms(integration, webhook_config, default_timeout_ms)
  end

  defp integration_metadata(integration, webhook_config, default_engine) do
    callback_retry = callback_retry_config(integration, webhook_config)

    %{
      session_key: Request.fetch(integration, :session_key),
      agent_id: Request.fetch(integration, :agent_id),
      queue_mode: resolve_queue_mode(integration),
      default_engine: resolve_engine(integration, default_engine),
      cwd: Request.normalize_blank(Request.fetch(integration, :cwd)),
      callback_url_configured:
        is_binary(Request.normalize_blank(Request.fetch(integration, :callback_url))),
      allow_callback_override: allow_callback_override?(integration, webhook_config),
      allow_private_callback_hosts: allow_private_callback_hosts?(integration, webhook_config),
      callback_max_attempts: callback_retry.max_attempts,
      callback_backoff_ms: callback_retry.backoff_ms,
      callback_backoff_max_ms: callback_retry.backoff_max_ms,
      mode: resolve_mode(integration, webhook_config),
      timeout_ms: resolve_timeout_ms(integration, webhook_config, 30_000),
      callback_wait_timeout_ms:
        Request.resolve_callback_wait_timeout_ms(integration, webhook_config, 10 * 60 * 1000),
      allow_query_token: allow_query_token?(integration, webhook_config),
      allow_payload_token: allow_payload_token?(integration, webhook_config),
      allow_payload_idempotency_key: allow_payload_idempotency_key?(integration, webhook_config)
    }
  end

  defp resolve_session_key(integration) do
    case Request.normalize_blank(Request.fetch(integration, :session_key)) do
      session_key when is_binary(session_key) ->
        session_key

      _ ->
        SessionKey.main(
          Request.normalize_blank(Request.fetch(integration, :agent_id)) || "default"
        )
    end
  end

  defp resolve_engine(integration, default_engine) do
    Request.normalize_blank(Request.fetch(integration, :default_engine)) || default_engine
  end

  defp resolve_queue_mode(integration) do
    case Request.fetch(integration, :queue_mode) do
      mode when mode in [:collect, :followup, :steer, :steer_backlog, :interrupt] -> mode
      "collect" -> :collect
      "followup" -> :followup
      "steer" -> :steer
      "steer_backlog" -> :steer_backlog
      "interrupt" -> :interrupt
      _ -> :collect
    end
  end

  defp resolve_mode(integration, webhook_config) do
    case parse_mode(Request.fetch(integration, :mode)) ||
           parse_mode(Request.fetch(webhook_config, :mode)) do
      :sync -> :sync
      _ -> :async
    end
  end

  defp parse_mode(nil), do: nil
  defp parse_mode(:sync), do: :sync
  defp parse_mode(:async), do: :async
  defp parse_mode("sync"), do: :sync
  defp parse_mode("async"), do: :async
  defp parse_mode(_), do: nil

  defp resolve_timeout_ms(integration, webhook_config, default_timeout_ms) do
    integration_timeout = Request.int_value(Request.fetch(integration, :timeout_ms), nil)
    webhook_timeout = Request.int_value(Request.fetch(webhook_config, :timeout_ms), nil)

    integration_timeout || webhook_timeout || default_timeout_ms
  end

  defp callback_retry_config(integration, webhook_config) do
    max_attempts =
      Request.int_value(
        first_non_blank([
          Request.fetch(integration, :callback_max_attempts),
          Request.fetch(webhook_config, :callback_max_attempts)
        ]),
        @default_callback_max_attempts
      )
      |> max(1)

    backoff_ms =
      Request.int_value(
        first_non_blank([
          Request.fetch(integration, :callback_backoff_ms),
          Request.fetch(webhook_config, :callback_backoff_ms)
        ]),
        @default_callback_backoff_ms
      )
      |> max(0)

    backoff_max_ms =
      Request.int_value(
        first_non_blank([
          Request.fetch(integration, :callback_backoff_max_ms),
          Request.fetch(webhook_config, :callback_backoff_max_ms)
        ]),
        @default_callback_backoff_max_ms
      )
      |> max(backoff_ms)

    %{max_attempts: max_attempts, backoff_ms: backoff_ms, backoff_max_ms: backoff_max_ms}
  end

  defp allow_callback_override?(integration, webhook_config),
    do: resolve_flag(integration, webhook_config, :allow_callback_override)

  defp allow_private_callback_hosts?(integration, webhook_config),
    do: resolve_flag(integration, webhook_config, :allow_private_callback_hosts)

  defp allow_query_token?(integration, webhook_config),
    do: resolve_flag(integration, webhook_config, :allow_query_token)

  defp allow_payload_token?(integration, webhook_config),
    do: resolve_flag(integration, webhook_config, :allow_payload_token)

  defp allow_payload_idempotency_key?(integration, webhook_config),
    do: resolve_flag(integration, webhook_config, :allow_payload_idempotency_key)

  defp resolve_flag(integration, webhook_config, key) do
    [Request.fetch(integration, key), Request.fetch(webhook_config, key)]
    |> Enum.find_value(false, &bool_value/1)
  end

  defp bool_value(value) when is_boolean(value), do: value
  defp bool_value(value) when value in [1, "1", "true", "TRUE", "yes", "YES"], do: true
  defp bool_value(value) when value in [0, "0", "false", "FALSE", "no", "NO"], do: false
  defp bool_value(_value), do: nil

  defp first_non_blank(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case Request.normalize_blank(value) do
        nil -> nil
        normalized -> normalized
      end
    end)
  end
end
