defmodule LemonGateway.Transports.Webhook.Config do
  @moduledoc """
  Runtime config and integration lookup helpers for the webhook transport.
  """

  require Logger
  alias LemonGateway.Transports.Webhook.Request

  @default_port 4046

  @spec enabled?() :: boolean()
  def enabled? do
    LemonCore.GatewayConfig.get(:enable_webhook, false) == true
  end

  @spec config() :: map()
  def config do
    LemonCore.GatewayConfig.get(:webhook, %{}) |> normalize_map()
  end

  @spec integration_config(binary()) :: map() | nil
  def integration_config(integration_id) when is_binary(integration_id) do
    integrations = Request.fetch(config(), :integrations)

    if is_map(integrations) do
      Enum.find_value(integrations, fn {key, value} ->
        if to_string(key) == integration_id do
          normalize_map(value)
        end
      end)
    end
  end

  def integration_config(_), do: nil

  @spec bind_ip(map()) :: :loopback | :any | tuple()
  def bind_ip(cfg) do
    cfg |> Request.fetch(:bind) |> LemonGateway.BindAddress.parse()
  end

  @spec port(map()) :: non_neg_integer()
  def port(cfg) do
    Request.int_value(Request.fetch(cfg, :port), @default_port)
  end

  @doc """
  Logs a warning for every security flag whose configured value is not a
  boolean. Such a value resolves to `false` (see `Request.resolve_flag/3`); an
  integration value never silently inherits a more permissive global value.
  """
  @spec warn_unsafe_integration_flags(map()) :: :ok
  def warn_unsafe_integration_flags(cfg) when is_map(cfg) do
    warn_invalid_flags("webhook", cfg)

    case Request.fetch(cfg, :integrations) do
      integrations when is_map(integrations) ->
        Enum.each(integrations, fn {id, integration} ->
          warn_invalid_flags("webhook integration #{inspect(to_string(id))}", integration)
        end)

      _ ->
        :ok
    end
  end

  def warn_unsafe_integration_flags(_cfg), do: :ok

  defp warn_invalid_flags(scope, section) do
    Request.security_flags()
    |> Enum.filter(fn key ->
      value = Request.fetch(section, key)
      not is_nil(value) and Request.flag_value(value) == :invalid
    end)
    |> Enum.each(fn key ->
      Logger.warning(
        "#{scope}: #{key} is not a boolean; treating it as false instead of inheriting " <>
          "the global webhook value"
      )
    end)
  end

  defp normalize_map(map) when is_map(map), do: map

  defp normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Enum.into(list, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}
end
