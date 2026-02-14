defmodule LemonGateway.Telegram.StartupNotifierTest do
  use ExUnit.Case, async: false

  alias LemonGateway.TestSupport.MockTelegramAPI

  setup do
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_core)

    MockTelegramAPI.reset!(notify_pid: self())

    on_exit(fn ->
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_core)

      MockTelegramAPI.stop()

      Application.delete_env(:lemon_gateway, LemonGateway.Config)
      Application.delete_env(:lemon_gateway, :telegram)
    end)

    :ok
  end

  test "sends startup_message to bound Telegram chat(s)" do
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      enable_telegram: true,
      telegram: %{
        bot_token: "test_token",
        startup_message: "gateway up"
      },
      bindings: [
        %{transport: "telegram", chat_id: 12_345}
      ]
    })

    Application.put_env(:lemon_gateway, :telegram, %{api_mod: MockTelegramAPI})

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert_receive {:telegram_api_call, {:send_message, 12_345, "gateway up", %{}, nil}}, 1_000
  end

  test "startup_message true uses a default message" do
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      enable_telegram: true,
      telegram: %{
        bot_token: "test_token",
        startup_message: true
      },
      bindings: [
        %{transport: :telegram, chat_id: 99_001, topic_id: 777}
      ]
    })

    Application.put_env(:lemon_gateway, :telegram, %{api_mod: MockTelegramAPI})

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    assert_receive {:telegram_api_call, {:send_message, 99_001, text, opts, nil}}, 1_000
    assert is_binary(text)
    assert String.starts_with?(text, "Lemon gateway online (")
    assert opts[:message_thread_id] == 777
  end
end
