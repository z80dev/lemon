defmodule LemonChannels.GatewayConfigTest do
  use ExUnit.Case, async: false

  alias LemonChannels.GatewayConfig

  @gateway_config_key :"Elixir.LemonGateway.Config"

  defmodule MockApi do
  end

  setup do
    old_gateway_env = Application.get_env(:lemon_gateway, @gateway_config_key)

    _ = Application.stop(:lemon_channels)

    on_exit(fn ->
      restore_env(:lemon_gateway, @gateway_config_key, old_gateway_env)
      _ = Application.ensure_all_started(:lemon_channels)
    end)

    :ok
  end

  test "reads config from LemonCore baseline when no runtime overrides are set" do
    Application.delete_env(:lemon_gateway, @gateway_config_key)
    assert GatewayConfig.get(:__missing_key__, :fallback) == :fallback
  end

  test "reads gateway env from full-replacement config" do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_telegram: true,
      max_concurrent_runs: 9,
      telegram: %{bot_token: "from-config", debounce_ms: 111}
    })

    assert GatewayConfig.get(:enable_telegram, false) == true
    assert GatewayConfig.get(:max_concurrent_runs, 0) == 9

    telegram = GatewayConfig.get(:telegram, %{})
    assert fetch(telegram, :bot_token) == "from-config"
    assert fetch(telegram, :debounce_ms) == 111
  end

  test "full-replacement config supports nested adapter sections" do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      telegram: %{
        bot_token: "from-config",
        poll_interval_ms: 100,
        api_mod: MockApi
      }
    })

    telegram = GatewayConfig.get(:telegram, %{})

    assert fetch(telegram, :bot_token) == "from-config"
    assert fetch(telegram, :poll_interval_ms) == 100
    assert fetch(telegram, :api_mod) == MockApi
  end

  test "full-replacement config supports xmtp section" do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      xmtp: %{
        connect_timeout_ms: 2500,
        require_live: true,
        poll_interval_ms: 300
      }
    })

    xmtp = GatewayConfig.get(:xmtp, %{})

    assert fetch(xmtp, :require_live) == true
    assert fetch(xmtp, :connect_timeout_ms) == 2500
    assert fetch(xmtp, :poll_interval_ms) == 300
  end

  test "ignores non-map full-replacement config" do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{bindings: [:something]})
    assert GatewayConfig.get(:bindings, :missing) == [:something]

    # Non-map values like plain strings are rejected by full_replacement_config
    Application.put_env(:lemon_gateway, @gateway_config_key, "not a map at all")
    # Falls through to TOML base, so :bindings won't be :something anymore
    result = GatewayConfig.get(:bindings, :missing)
    refute result == [:something]
  end

  defp restore_env(_app, _key, nil), do: Application.delete_env(:lemon_gateway, @gateway_config_key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end
end
