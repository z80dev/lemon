defmodule LemonChannels.Adapters.Telegram.OutboundAccountTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Outbound
  alias LemonChannels.OutboundPayload

  @gateway_key :gateway_test_config

  defmodule CaptureAPI do
    def send_message(token, chat, text, opts, mode) do
      send(self(), {:sent, token, chat, text, opts, mode})
      {:ok, %{message_id: 42}}
    end

    def edit_message_text(token, chat, message, text, opts) do
      send(self(), {:edited, token, chat, message, text, opts})
      {:ok, %{message_id: message}}
    end

    def delete_message(token, chat, message) do
      send(self(), {:deleted, token, chat, message})
      {:ok, %{message_id: message}}
    end
  end

  setup do
    gateway = Application.get_env(:lemon_core, @gateway_key)
    test_mode = Application.get_env(:lemon_core, :config_test_mode)
    Application.put_env(:lemon_core, :config_test_mode, true)

    on_exit(fn ->
      restore(:lemon_core, @gateway_key, gateway)
      restore(:lemon_core, :config_test_mode, test_mode)
    end)
  end

  test "named canonical account uses only its configured token and preserves the topic" do
    configure(%{account_id: "work", bot_token: "fake-work-token"})
    assert {:ok, _} = Outbound.deliver(payload("work"))
    assert_receive {:sent, "fake-work-token", -100, "notice", %{message_thread_id: 77}, nil}
    assert {:error, :telegram_account_mismatch} = Outbound.deliver(payload("default"))
    assert {:error, :telegram_account_mismatch} = Outbound.deliver(payload("other"))
    refute_receive {:sent, _, _, _, _, _}
  end

  test "only the default account may use a config without an account identity" do
    configure(%{bot_token: "fake-default-token"})
    assert {:ok, _} = Outbound.deliver(payload("default"))
    assert_receive {:sent, "fake-default-token", -100, _, _, _}
    assert {:error, :telegram_account_mismatch} = Outbound.deliver(payload("work"))
    assert {:error, :telegram_account_mismatch} = Outbound.deliver(payload(nil))
    assert {:error, :telegram_account_mismatch} = Outbound.deliver(payload(""))
    refute_receive {:sent, _, _, _, _, _}
  end

  test "string-keyed canonical account configuration is exact too" do
    configure(%{"account_id" => "named", "bot_token" => "fake-named-token"})
    assert {:ok, _} = Outbound.deliver(payload("named"))
    assert_receive {:sent, "fake-named-token", -100, _, _, _}
    assert {:error, :telegram_account_mismatch} = Outbound.deliver(payload("default"))
  end

  test "mismatched edits, deletes and files are rejected before any side effect" do
    configure(%{account_id: "work", bot_token: "fake-work-token"})

    for {kind, content} <- [
          {:edit, %{message_id: "42", text: "replacement"}},
          {:delete, %{message_id: "42"}},
          {:file, %{path: "/must/not/read"}}
        ] do
      outbound = %{payload("other") | kind: kind, content: content}
      assert {:error, :telegram_account_mismatch} = Outbound.deliver(outbound)
    end

    refute_receive {:edited, _, _, _, _, _}
    refute_receive {:deleted, _, _, _}
  end

  defp configure(config) do
    config = Map.merge(%{api_mod: CaptureAPI, use_markdown: false}, config)
    Application.put_env(:lemon_core, @gateway_key, %{telegram: config})
  end

  defp payload(account) do
    OutboundPayload.text(
      "telegram",
      account,
      %{kind: :group, id: "-100", thread_id: "77"},
      "notice"
    )
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
