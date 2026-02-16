defmodule LemonChannels.GatewayConfigTest do
  use ExUnit.Case, async: false

  alias LemonChannels.GatewayConfig

  defmodule MockApi do
  end

  setup do
    old_gateway_config_env = Application.get_env(:lemon_gateway, LemonGateway.Config)
    old_telegram_env = Application.get_env(:lemon_gateway, :telegram)

    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_gateway)

    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :telegram)

    on_exit(fn ->
      restore_env(:lemon_gateway, LemonGateway.Config, old_gateway_config_env)
      restore_env(:lemon_gateway, :telegram, old_telegram_env)
      _ = Application.ensure_all_started(:lemon_gateway)
      _ = Application.ensure_all_started(:lemon_channels)
    end)

    :ok
  end

  test "reads config without LemonGateway.Config process" do
    assert Process.whereis(LemonGateway.Config) == nil
    assert GatewayConfig.get(:__missing_key__, :fallback) == :fallback
    refute GatewayConfig.get(:max_concurrent_runs, :fallback) == :fallback
  end

  test "applies LemonGateway.Config env overrides over base config" do
    assert Process.whereis(LemonGateway.Config) == nil

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
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

  test "merges :telegram runtime env overrides on top of gateway config" do
    assert Process.whereis(LemonGateway.Config) == nil

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      telegram: %{
        bot_token: "from-config",
        poll_interval_ms: 100
      }
    })

    Application.put_env(:lemon_gateway, :telegram, %{
      poll_interval_ms: 25,
      api_mod: MockApi
    })

    telegram = GatewayConfig.get(:telegram, %{})

    assert fetch(telegram, :bot_token) == "from-config"
    assert fetch(telegram, :poll_interval_ms) == 25
    assert fetch(telegram, :api_mod) == MockApi
  end

  test "supports legacy non-keyword LemonGateway.Config env as bindings list" do
    assert Process.whereis(LemonGateway.Config) == nil

    bindings = [%{transport: :telegram, chat_id: 1234}]
    Application.put_env(:lemon_gateway, LemonGateway.Config, bindings)

    assert GatewayConfig.get(:bindings, []) == bindings
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      Map.has_key?(map, string_key) ->
        Map.get(map, string_key)

      true ->
        nil
    end
  end
end
