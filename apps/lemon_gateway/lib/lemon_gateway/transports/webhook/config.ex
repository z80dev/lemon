defmodule LemonGateway.Transports.Webhook.Config do
  @moduledoc """
  Runtime config and integration lookup helpers for the webhook transport.
  """

  alias LemonGateway.Transports.Webhook.Request

  @default_port 4046

  @spec enabled?() :: boolean()
  def enabled? do
    LemonGateway.Config.get_or_env(:enable_webhook, false) == true
  rescue
    _ -> false
  end

  @spec config() :: map()
  def config do
    LemonGateway.Config.get_or_env(:webhook, %{}) |> normalize_map()
  rescue
    _ -> %{}
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

  defp normalize_map(map) when is_map(map), do: map

  defp normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Enum.into(list, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}
end
