defmodule LemonChannels.Adapters.Xmtp.Bridge do
  @moduledoc false

  alias LemonChannels.PortBridge

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

    PortBridge.command(port_server, payload)
  end

  @doc """
  Ask the bridge for new messages. `cursors` maps a conversation id to the
  decimal `sent_at_ns` high-water mark; the bridge emits only later messages.
  """
  @spec poll(pid(), %{binary() => binary()}) :: :ok
  def poll(port_server, cursors) when is_pid(port_server) and is_map(cursors) do
    PortBridge.command(port_server, %{"op" => "poll", "cursors" => cursors})
  end

  @spec acknowledge_inbound(pid(), binary()) :: :ok
  def acknowledge_inbound(port_server, dedupe_key)
      when is_pid(port_server) and is_binary(dedupe_key) do
    PortBridge.command(port_server, %{"op" => "ack_inbound", "dedupe_key" => dedupe_key})
  end

  def acknowledge_inbound(_port_server, _dedupe_key), do: :ok

  @spec send_message(pid(), map()) :: :ok
  def send_message(port_server, payload) when is_pid(port_server) and is_map(payload) do
    command =
      payload
      |> Map.put("op", "send")
      |> drop_nil_values()

    PortBridge.command(port_server, command)
  end

  defp cfg_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, to_string(key))
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
