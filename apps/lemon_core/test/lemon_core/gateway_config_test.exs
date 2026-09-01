defmodule LemonCore.GatewayConfigTest do
  use ExUnit.Case, async: false

  alias LemonCore.GatewayConfig

  # The test-mode replacement layer: a full gateway config under the gateway
  # app's env, read before the TOML section while config_test_mode is on.
  @replacement_key :"Elixir.LemonGateway.Config"

  defmodule MockApi do
  end

  setup do
    original = Application.get_env(:lemon_gateway, @replacement_key)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_gateway, @replacement_key)
      else
        Application.put_env(:lemon_gateway, @replacement_key, original)
      end
    end)

    :ok
  end

  test "reads the canonical config when no replacement is set" do
    Application.delete_env(:lemon_gateway, @replacement_key)
    assert GatewayConfig.get(:__missing_key__, :fallback) == :fallback
  end

  test "reads a full-replacement config" do
    Application.put_env(:lemon_gateway, @replacement_key, %{
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

  test "a replacement config carries nested adapter sections" do
    Application.put_env(:lemon_gateway, @replacement_key, %{
      telegram: %{bot_token: "from-config", poll_interval_ms: 100, api_mod: MockApi},
      xmtp: %{connect_timeout_ms: 2500, require_live: true, poll_interval_ms: 300}
    })

    telegram = GatewayConfig.get(:telegram, %{})
    assert GatewayConfig.fetch(telegram, :api_mod, nil) == MockApi
    assert GatewayConfig.fetch(telegram, :poll_interval_ms, nil) == 100

    xmtp = GatewayConfig.get(:xmtp, %{})
    assert GatewayConfig.fetch(xmtp, :require_live, nil) == true
    assert GatewayConfig.fetch(xmtp, :connect_timeout_ms, nil) == 2500
  end

  test "a keyword replacement is read as a map and a bare list as bindings" do
    Application.put_env(:lemon_gateway, @replacement_key, max_concurrent_runs: 3)
    assert GatewayConfig.get(:max_concurrent_runs, :missing) == 3

    Application.put_env(:lemon_gateway, @replacement_key, [%{transport: :demo}])
    assert GatewayConfig.get(:bindings, :missing) == [%{transport: :demo}]
  end

  test "a replacement that is not a config is ignored" do
    Application.put_env(:lemon_gateway, @replacement_key, %{bindings: [:something]})
    assert GatewayConfig.get(:bindings, :missing) == [:something]

    Application.put_env(:lemon_gateway, @replacement_key, "not a map at all")
    refute GatewayConfig.get(:bindings, :missing) == [:something]
  end
end
