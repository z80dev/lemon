defmodule LemonChannels.Adapters.Telegram.ModelPolicyAdapterTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Telegram.StateStore

  test "resolve_model_hint prefers the session override over future defaults" do
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])
    session_key = "telegram:test:model:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = StateStore.delete_session_model(session_key)
      _ = StateStore.delete_default_model({"default", chat_id, topic_id})
    end)

    :ok =
      ModelPolicyAdapter.put_default_model_preference("default", chat_id, topic_id, "openai:gpt-5")

    :ok = ModelPolicyAdapter.put_session_model_override(session_key, "anthropic:claude-opus-4.1")

    assert {"anthropic:claude-opus-4.1", :session} =
             ModelPolicyAdapter.resolve_model_hint("default", session_key, chat_id, topic_id)
  end

  test "resolve_thinking_hint prefers topic overrides over chat defaults" do
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])

    on_exit(fn ->
      _ = StateStore.delete_default_thinking({"default", chat_id, nil})
      _ = StateStore.delete_default_thinking({"default", chat_id, topic_id})
    end)

    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", chat_id, nil, "low")
    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", chat_id, topic_id, "high")

    assert {"high", :topic} = ModelPolicyAdapter.resolve_thinking_hint("default", chat_id, topic_id)
  end

  test "format_thinking_line reports the effective scope" do
    assert "high (topic default)" = ModelPolicyAdapter.format_thinking_line("high", :topic)
    assert "low (chat default)" = ModelPolicyAdapter.format_thinking_line("low", :chat)
    assert "(default)" = ModelPolicyAdapter.format_thinking_line(nil, nil)
  end
end
