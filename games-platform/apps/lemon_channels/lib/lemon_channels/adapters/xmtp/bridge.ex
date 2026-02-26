defmodule LemonChannels.Adapters.Xmtp.Bridge do
  @moduledoc false

  alias LemonChannels.Adapters.Xmtp.PortServer

  @spec connect(pid(), map()) :: :ok
  def connect(port_server, cfg) when is_pid(port_server) and is_map(cfg) do
    payload =
      %{
        "op" => "connect",
        "env" => cfg_value(cfg, :env) || cfg_value(cfg, :environment),
        "api_url" => cfg_value(cfg, :api_url),
        "wallet_address" => cfg_value(cfg, :wallet_address),
        "wallet_key" => cfg_value(cfg, :wallet_key),
        "private_key" => cfg_value(cfg, :private_key),
        "inbox_id" => cfg_value(cfg, :inbox_id),
        "db_path" => cfg_value(cfg, :db_path),
        "mock_mode" => cfg_value(cfg, :mock_mode),
        "sdk_module" => cfg_value(cfg, :sdk_module)
      }
      |> drop_nil_values()

    PortServer.command(port_server, payload)
  end

  @spec poll(pid()) :: :ok
  def poll(port_server) when is_pid(port_server) do
    PortServer.command(port_server, %{"op" => "poll"})
  end

  @spec send_message(pid(), map()) :: :ok
  def send_message(port_server, payload) when is_pid(port_server) and is_map(payload) do
    command =
      payload
      |> Map.put("op", "send")
      |> drop_nil_values()

    PortServer.command(port_server, command)
  end

  defp cfg_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, to_string(key))
  end

  defp cfg_value(_, _), do: nil

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
