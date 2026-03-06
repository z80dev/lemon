defmodule LemonGateway.Transports.Webhook.Config do
  @moduledoc """
  Runtime config and integration lookup helpers for the webhook transport.
  """

  alias LemonGateway.Transports.Webhook.Request

  @default_port if(Code.ensure_loaded?(Mix) and Mix.env() == :test, do: 0, else: 4046)

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

    normalize_map(cfg)
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
    case Request.normalize_blank(Request.fetch(cfg, :bind)) do
      nil -> :loopback
      "127.0.0.1" -> :loopback
      "localhost" -> :loopback
      "0.0.0.0" -> :any
      "any" -> :any
      other -> parse_ip(other) || :loopback
    end
  end

  @spec port(map()) :: non_neg_integer()
  def port(cfg) do
    Request.int_value(Request.fetch(cfg, :port), @default_port)
  end

  @spec default_engine() :: binary()
  def default_engine do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:default_engine) || "lemon"
    else
      resolve_from_app_config(:default_engine) || "lemon"
    end
  rescue
    _ -> "lemon"
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

  defp normalize_map(map) when is_map(map), do: map

  defp normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Enum.into(list, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}

  defp resolve_from_app_config(key) do
    cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

    cond do
      is_list(cfg) and Keyword.keyword?(cfg) -> Keyword.get(cfg, key)
      is_map(cfg) -> Request.fetch(cfg, key)
      true -> nil
    end
  end
end
