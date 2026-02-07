defmodule LemonGateway.Telegram.TriggerModeTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Telegram.TriggerMode
  alias LemonGateway.Types.ChatScope

  setup do
    Application.put_env(:lemon_core, LemonCore.Store, backend: LemonCore.Store.EtsBackend)

    if is_nil(Process.whereis(LemonCore.Store)) do
      {:ok, _} = start_supervised(LemonCore.Store)
    end

    for {key, _} <- LemonCore.Store.list(:telegram_chat_trigger_mode) do
      LemonCore.Store.delete(:telegram_chat_trigger_mode, key)
    end

    for {key, _} <- LemonCore.Store.list(:telegram_topic_trigger_mode) do
      LemonCore.Store.delete(:telegram_topic_trigger_mode, key)
    end

    :ok
  end

  test "defaults to all when nothing is set" do
    assert %{mode: :all, source: :default} = TriggerMode.resolve("default", 111, nil)
  end

  test "sets chat default mode" do
    scope = %ChatScope{transport: :telegram, chat_id: 222, topic_id: nil}
    assert :ok = TriggerMode.set(scope, "default", :mentions)

    resolved = TriggerMode.resolve("default", 222, nil)
    assert resolved.mode == :mentions
    assert resolved.chat_mode == :mentions
    assert resolved.source == :chat
  end

  test "topic override wins over chat default" do
    chat = %ChatScope{transport: :telegram, chat_id: 333, topic_id: nil}
    topic = %ChatScope{transport: :telegram, chat_id: 333, topic_id: 444}

    assert :ok = TriggerMode.set(chat, "default", :all)
    assert :ok = TriggerMode.set(topic, "default", :mentions)

    resolved = TriggerMode.resolve("default", 333, 444)
    assert resolved.mode == :mentions
    assert resolved.topic_mode == :mentions
    assert resolved.source == :topic
  end

  test "clears topic override" do
    chat = %ChatScope{transport: :telegram, chat_id: 555, topic_id: nil}
    topic = %ChatScope{transport: :telegram, chat_id: 555, topic_id: 777}

    assert :ok = TriggerMode.set(chat, "default", :mentions)
    assert :ok = TriggerMode.set(topic, "default", :all)

    assert :ok = TriggerMode.clear_topic("default", 555, 777)

    resolved = TriggerMode.resolve("default", 555, 777)
    assert resolved.mode == :mentions
    assert resolved.topic_mode == nil
    assert resolved.source == :chat
  end
end
