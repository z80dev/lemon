defmodule LemonChannels.GatewayConfigTest do
  use ExUnit.Case, async: false

  alias LemonChannels.GatewayConfig

  defmodule MockApi do
  end

  setup do
    old_gateway_env = Application.get_env(:lemon_channels, :gateway)
    old_telegram_env = Application.get_env(:lemon_channels, :telegram)

    _ = Application.stop(:lemon_channels)

    Application.delete_env(:lemon_channels, :gateway)
    Application.delete_env(:lemon_channels, :telegram)

    on_exit(fn ->
      restore_env(:lemon_channels, :gateway, old_gateway_env)
      restore_env(:lemon_channels, :telegram, old_telegram_env)
      _ = Application.ensure_all_started(:lemon_channels)
    end)

    :ok
  end

  test "reads config from LemonCore baseline when no runtime overrides are set" do
    assert GatewayConfig.get(:__missing_key__, :fallback) == :fallback
    refute GatewayConfig.get(:max_concurrent_runs, :fallback) == :fallback
  end

  test "applies :lemon_channels gateway env overrides" do
    Application.put_env(:lemon_channels, :gateway, %{
      "enable_telegram" => true,
      max_concurrent_runs: 9,
      telegram: %{"bot_token" => "from-config", debounce_ms: 111}
    })

    assert GatewayConfig.get(:enable_telegram, false) == true
    assert GatewayConfig.get(:max_concurrent_runs, 0) == 9

    telegram = GatewayConfig.get(:telegram, %{})
    assert fetch(telegram, :bot_token) == "from-config"
    assert fetch(telegram, :debounce_ms) == 111
  end

  test "merges :telegram runtime overrides on top of gateway telegram config" do
    Application.put_env(:lemon_channels, :gateway, %{
      telegram: %{
        bot_token: "from-config",
        poll_interval_ms: 100
      }
    })

    Application.put_env(:lemon_channels, :telegram, %{
      poll_interval_ms: 25,
      api_mod: MockApi
    })

    telegram = GatewayConfig.get(:telegram, %{})

    assert fetch(telegram, :bot_token) == "from-config"
    assert fetch(telegram, :poll_interval_ms) == 25
    assert fetch(telegram, :api_mod) == MockApi
  end

  test "ignores non-map gateway runtime config" do
    baseline = GatewayConfig.get(:bindings, :missing)
    Application.put_env(:lemon_channels, :gateway, [:not, :a, :map])
    assert GatewayConfig.get(:bindings, :missing) == baseline
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
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
