defmodule LemonChannels.Adapters.Telegram.TransportModelPreferencesTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.ModelPreferences
  alias LemonChannels.Telegram.StateStore
  alias LemonCore.ChatScope

  test "resolve_model_hint prefers the session override over future defaults" do
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])
    session_key = "telegram:test:model:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = StateStore.delete_session_model(session_key)
      _ = StateStore.delete_default_model({"default", chat_id, topic_id})
    end)

    :ok =
      ModelPreferences.put_default_model_preference("default", chat_id, topic_id, "openai:gpt-5")

    :ok = ModelPreferences.put_session_model_override(session_key, "anthropic:claude-opus-4.1")

    assert {"anthropic:claude-opus-4.1", :session} =
             ModelPreferences.resolve_model_hint("default", session_key, chat_id, topic_id)
  end

  test "resolve_thinking_hint prefers topic overrides over chat defaults" do
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])

    on_exit(fn ->
      _ = StateStore.delete_default_thinking({"default", chat_id, nil})
      _ = StateStore.delete_default_thinking({"default", chat_id, topic_id})
    end)

    :ok = ModelPreferences.put_default_thinking_preference("default", chat_id, nil, "low")
    :ok = ModelPreferences.put_default_thinking_preference("default", chat_id, topic_id, "high")

    assert {"high", :topic} = ModelPreferences.resolve_thinking_hint("default", chat_id, topic_id)
  end

  test "render_thinking_status reports the effective scope" do
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])
    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}

    on_exit(fn ->
      _ = StateStore.delete_default_thinking({"default", chat_id, topic_id})
    end)

    :ok = ModelPreferences.put_default_thinking_preference("default", chat_id, topic_id, "medium")

    text = ModelPreferences.render_thinking_status("default", scope)

    assert text =~ "Thinking level for this topic: medium (topic default)"
    assert text =~ "Topic override: medium."
  end
end
