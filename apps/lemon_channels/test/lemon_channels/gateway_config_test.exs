defmodule LemonChannels.GatewayConfigTest do
  use ExUnit.Case, async: false

  alias LemonChannels.GatewayConfig

  defmodule MockApi do
  end

  setup do
    old_gateway_env = Application.get_env(:lemon_channels, :gateway)
    old_telegram_env = Application.get_env(:lemon_channels, :telegram)
    old_xmtp_env = Application.get_env(:lemon_channels, :xmtp)

    _ = Application.stop(:lemon_channels)

    Application.delete_env(:lemon_channels, :gateway)
    Application.delete_env(:lemon_channels, :telegram)
    Application.delete_env(:lemon_channels, :xmtp)

    on_exit(fn ->
      restore_env(:lemon_channels, :gateway, old_gateway_env)
      restore_env(:lemon_channels, :telegram, old_telegram_env)
      restore_env(:lemon_channels, :xmtp, old_xmtp_env)
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

  test "merges :xmtp runtime overrides on top of gateway xmtp config" do
    Application.put_env(:lemon_channels, :gateway, %{
      xmtp: %{
        connect_timeout_ms: 1000,
        require_live: true
      }
    })

    Application.put_env(:lemon_channels, :xmtp, %{
      connect_timeout_ms: 2500,
      poll_interval_ms: 300
    })

    xmtp = GatewayConfig.get(:xmtp, %{})

    assert fetch(xmtp, :require_live) == true
    assert fetch(xmtp, :connect_timeout_ms) == 2500
    assert fetch(xmtp, :poll_interval_ms) == 300
  end

  describe "get_telegram/2" do
    test "returns value from telegram sub-config" do
      Application.put_env(:lemon_channels, :telegram, %{progress_reactions: true})
      assert GatewayConfig.get_telegram(:progress_reactions, :missing) == true
    end

    test "returns default when key is absent" do
      Application.put_env(:lemon_channels, :telegram, %{})
      # Use a key that won't exist in any real config file.
      assert GatewayConfig.get_telegram(:__test_nonexistent_key__, :default_val) == :default_val
    end

    test "returns false (not default) when key is explicitly false — boolean correctness" do
      Application.put_env(:lemon_channels, :telegram, %{progress_reactions: false})
      assert GatewayConfig.get_telegram(:progress_reactions, true) == false
    end

    test "returns false for show_tool_status when explicitly false" do
      Application.put_env(:lemon_channels, :telegram, %{show_tool_status: false})
      assert GatewayConfig.get_telegram(:show_tool_status, true) == false
    end

    test "returns false for reply_to_user_message when explicitly false" do
      Application.put_env(:lemon_channels, :telegram, %{reply_to_user_message: false})
      assert GatewayConfig.get_telegram(:reply_to_user_message, true) == false
    end

    test "handles string-keyed telegram config" do
      Application.put_env(:lemon_channels, :telegram, %{"progress_reactions" => false})
      assert GatewayConfig.get_telegram(:progress_reactions, true) == false
    end
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
