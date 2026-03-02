defmodule LemonGateway.Transports.Webhook.Routing do
  @moduledoc """
  Integration configuration resolution and session-key derivation for webhook transport.

  Resolves integration-specific settings such as session key, engine, queue mode,
  response mode, timeout, and callback configuration by merging integration-level
  overrides with global webhook defaults.
  """

  import LemonGateway.Transports.Webhook.Helpers

  alias LemonCore.SessionKey

  @default_timeout_ms 30_000
  @default_callback_wait_timeout_ms 10 * 60 * 1000
  @default_callback_max_attempts 3
  @default_callback_backoff_ms 500
  @default_callback_backoff_max_ms 5_000

  @doc """
  Resolves the session key for an integration, falling back to a default
  derived from the agent_id.
  """
  @spec resolve_session_key(map()) :: String.t()
  def resolve_session_key(integration) do
    case normalize_blank(fetch(integration, :session_key)) do
      session_key when is_binary(session_key) ->
        session_key

      _ ->
        agent_id = normalize_blank(fetch(integration, :agent_id)) || "default"
        SessionKey.main(agent_id)
    end
  end

  @doc """
  Resolves the engine ID from integration config, falling back to the global default.
  """
  @spec resolve_engine(map()) :: String.t()
  def resolve_engine(integration) do
    normalize_blank(fetch(integration, :default_engine)) || default_engine()
  end

  @doc """
  Resolves the queue mode from integration config.
  """
  @spec resolve_queue_mode(map()) :: atom()
  def resolve_queue_mode(integration) do
    case fetch(integration, :queue_mode) do
      mode when mode in [:collect, :followup, :steer, :steer_backlog, :interrupt] ->
        mode

      "collect" ->
        :collect

      "followup" ->
        :followup

      "steer" ->
        :steer

      "steer_backlog" ->
        :steer_backlog

      "interrupt" ->
        :interrupt

      _ ->
        :collect
    end
  end

  @doc """
  Resolves the response mode (:sync or :async) from integration config,
  falling back to the global webhook config.
  """
  @spec resolve_mode(map(), map()) :: :sync | :async
  def resolve_mode(integration, webhook_config \\ %{}) do
    case parse_mode(fetch(integration, :mode)) || parse_mode(fetch(webhook_config, :mode)) do
      :sync -> :sync
      _ -> :async
    end
  end

  @doc """
  Normalizes a mode atom or string into its string representation.
  """
  @spec normalize_mode_string(term()) :: String.t() | nil
  def normalize_mode_string(mode) when mode in [:sync, :async], do: Atom.to_string(mode)
  def normalize_mode_string(mode) when mode in ["sync", "async"], do: mode
  def normalize_mode_string(_), do: nil

  @doc """
  Resolves the timeout in milliseconds from integration config,
  falling back to the global webhook config and then the default.
  """
  @spec resolve_timeout_ms(map(), map()) :: integer()
  def resolve_timeout_ms(integration, webhook_config \\ %{}) do
    integration_timeout = int_value(fetch(integration, :timeout_ms), nil)
    webhook_timeout = int_value(fetch(webhook_config, :timeout_ms), nil)

    integration_timeout || webhook_timeout || @default_timeout_ms
  end

  @doc """
  Resolves the callback wait timeout in milliseconds.
  """
  @spec resolve_callback_wait_timeout_ms(map(), map()) :: integer()
  def resolve_callback_wait_timeout_ms(integration, webhook_config \\ %{}) do
    integration_timeout = int_value(fetch(integration, :callback_wait_timeout_ms), nil)
    webhook_timeout = int_value(fetch(webhook_config, :callback_wait_timeout_ms), nil)

    (integration_timeout || webhook_timeout || @default_callback_wait_timeout_ms)
    |> max(1)
  end

  @doc """
  Builds the callback retry configuration from integration and global settings.
  """
  @spec callback_retry_config(map(), map()) :: map()
  def callback_retry_config(integration, webhook_config \\ %{}) do
    max_attempts =
      int_value(
        first_non_blank([
          fetch(integration, :callback_max_attempts),
          fetch(webhook_config, :callback_max_attempts)
        ]),
        @default_callback_max_attempts
      )
      |> max(1)

    backoff_ms =
      int_value(
        first_non_blank([
          fetch(integration, :callback_backoff_ms),
          fetch(webhook_config, :callback_backoff_ms)
        ]),
        @default_callback_backoff_ms
      )
      |> max(0)

    backoff_max_ms =
      int_value(
        first_non_blank([
          fetch(integration, :callback_backoff_max_ms),
          fetch(webhook_config, :callback_backoff_max_ms)
        ]),
        @default_callback_backoff_max_ms
      )
      |> max(backoff_ms)

    %{max_attempts: max_attempts, backoff_ms: backoff_ms, backoff_max_ms: backoff_max_ms}
  end

  @doc """
  Resolves the callback URL from payload (if override is allowed) or integration config.
  """
  @spec resolve_callback_url(map(), map(), map()) :: String.t() | nil
  def resolve_callback_url(payload, integration, webhook_config \\ %{}) do
    configured_callback_url =
      first_non_blank([
        fetch(integration, :callback_url),
        fetch(webhook_config, :callback_url)
      ])

    if allow_callback_override?(integration, webhook_config) do
      first_non_blank([payload_callback_url(payload), configured_callback_url])
    else
      configured_callback_url
    end
  end

  @doc """
  Returns whether private callback hosts are allowed for this integration.
  """
  @spec allow_private_callback_hosts?(map(), map()) :: boolean()
  def allow_private_callback_hosts?(integration, webhook_config \\ %{}) do
    resolve_integration_flag(integration, webhook_config, :allow_private_callback_hosts)
  end

  @doc """
  Returns whether the integration allows query-string tokens.
  """
  @spec allow_query_token?(map(), map()) :: boolean()
  def allow_query_token?(integration, webhook_config \\ %{}) do
    resolve_integration_flag(integration, webhook_config, :allow_query_token)
  end

  @doc """
  Returns whether the integration allows payload tokens.
  """
  @spec allow_payload_token?(map(), map()) :: boolean()
  def allow_payload_token?(integration, webhook_config \\ %{}) do
    resolve_integration_flag(integration, webhook_config, :allow_payload_token)
  end

  @doc """
  Returns whether the integration allows payload-based idempotency keys.
  """
  @spec allow_payload_idempotency_key?(map(), map()) :: boolean()
  def allow_payload_idempotency_key?(integration, webhook_config \\ %{}) do
    resolve_integration_flag(integration, webhook_config, :allow_payload_idempotency_key)
  end

  @doc """
  Returns whether the integration allows callback URL override from the payload.
  """
  @spec allow_callback_override?(map(), map()) :: boolean()
  def allow_callback_override?(integration, webhook_config \\ %{}) do
    resolve_integration_flag(integration, webhook_config, :allow_callback_override)
  end

  @doc """
  Builds an integration metadata map for logging/tracing.
  """
  @spec integration_metadata(map(), map()) :: map()
  def integration_metadata(integration, webhook_config \\ %{}) do
    callback_retry = callback_retry_config(integration, webhook_config)

    %{
      session_key: fetch(integration, :session_key),
      agent_id: fetch(integration, :agent_id),
      queue_mode: resolve_queue_mode(integration),
      default_engine: resolve_engine(integration),
      cwd: normalize_blank(fetch(integration, :cwd)),
      callback_url_configured: is_binary(normalize_blank(fetch(integration, :callback_url))),
      allow_callback_override: allow_callback_override?(integration, webhook_config),
      allow_private_callback_hosts: allow_private_callback_hosts?(integration, webhook_config),
      callback_max_attempts: callback_retry.max_attempts,
      callback_backoff_ms: callback_retry.backoff_ms,
      callback_backoff_max_ms: callback_retry.backoff_max_ms,
      mode: resolve_mode(integration, webhook_config),
      timeout_ms: resolve_timeout_ms(integration, webhook_config),
      callback_wait_timeout_ms: resolve_callback_wait_timeout_ms(integration, webhook_config),
      allow_query_token: allow_query_token?(integration, webhook_config),
      allow_payload_token: allow_payload_token?(integration, webhook_config),
      allow_payload_idempotency_key: allow_payload_idempotency_key?(integration, webhook_config)
    }
  end

  # --- Private helpers ---

  defp parse_mode(nil), do: nil
  defp parse_mode(:sync), do: :sync
  defp parse_mode(:async), do: :async
  defp parse_mode("sync"), do: :sync
  defp parse_mode("async"), do: :async
  defp parse_mode(_), do: nil

  defp payload_callback_url(payload) do
    first_non_blank([
      fetch_any(payload, [["callback_url"]]),
      fetch_any(payload, [["callbackUrl"]]),
      fetch_any(payload, [["callback", "url"]])
    ])
  end

  defp resolve_integration_flag(integration, webhook_config, key) do
    resolve_boolean([fetch(integration, key), fetch(webhook_config, key)], false)
  end

  defp default_engine do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:default_engine) || "lemon"
    else
      resolve_from_app_config(:default_engine) || "lemon"
    end
  rescue
    _ -> "lemon"
  end

  defp resolve_from_app_config(key) do
    cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

    cond do
      is_list(cfg) and Keyword.keyword?(cfg) -> Keyword.get(cfg, key)
      is_map(cfg) -> fetch(cfg, key)
      true -> nil
    end
  end
end
