defmodule LemonCore.GatewayConfigTest do
  use ExUnit.Case, async: false

  alias LemonCore.GatewayConfig

  @gateway_config_key :"Elixir.LemonGateway.Config"

  defmodule MockApi do
  end

  setup do
    old_gateway_env = Application.get_env(:lemon_gateway, @gateway_config_key)
    old_home = System.get_env("HOME")

    on_exit(fn ->
      restore_env(:lemon_gateway, @gateway_config_key, old_gateway_env)
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      LemonCore.ConfigCache.clear()
    end)

    :ok
  end

  test "reads config from the canonical TOML when no replacement is set" do
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
    assert GatewayConfig.fetch(telegram, :bot_token, nil) == "from-config"
    assert GatewayConfig.fetch(telegram, :debounce_ms, nil) == 111
  end

  test "full-replacement config supports nested adapter sections" do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      telegram: %{bot_token: "from-config", poll_interval_ms: 100, api_mod: MockApi}
    })

    telegram = GatewayConfig.get(:telegram, %{})
    assert GatewayConfig.fetch(telegram, :poll_interval_ms, nil) == 100
    assert GatewayConfig.fetch(telegram, :api_mod, nil) == MockApi
  end

  test "ignores a non-map full-replacement config" do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{bindings: [:something]})
    assert GatewayConfig.get(:bindings, :missing) == [:something]

    Application.put_env(:lemon_gateway, @gateway_config_key, "not a map at all")
    refute GatewayConfig.get(:bindings, :missing) == [:something]
  end

  # #617: an unloadable config is never read as an empty gateway section
  # (which used to boot the gateway with every channel silently disabled).
  test "an invalid [gateway] section raises instead of reading as defaults" do
    Application.delete_env(:lemon_gateway, @gateway_config_key)

    home =
      Path.join(System.tmp_dir!(), "gateway_config_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(home, ".lemon"))
    on_exit(fn -> File.rm_rf!(home) end)
    System.put_env("HOME", home)

    File.write!(Path.join([home, ".lemon", "config.toml"]), """
    [gateway]
    max_concurrent_runs = "many"
    enable_telegram = true
    """)

    LemonCore.ConfigCache.clear()

    assert_raise LemonCore.Config.ValidationError, fn -> GatewayConfig.get(:enable_telegram) end
    assert_raise LemonCore.Config.ValidationError, fn -> GatewayConfig.load() end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
