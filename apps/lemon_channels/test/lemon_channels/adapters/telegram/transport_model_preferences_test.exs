defmodule LemonChannels.Adapters.Telegram.ModelPolicyAdapterTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Telegram.StateStore
  alias LemonCore.ModelPolicy

  setup do
    ModelPolicy.list()
    |> Enum.each(fn {route, _policy} -> ModelPolicy.clear(route) end)

    :ok
  end

  test "resolve_model_hint prefers the session override over future defaults" do
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])
    session_key = "telegram:test:model:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = StateStore.delete_session_model(session_key)
      _ = StateStore.delete_default_model({"default", chat_id, topic_id})
    end)

    :ok =
      ModelPolicyAdapter.put_default_model_preference(
        "default",
        chat_id,
        topic_id,
        "openai:gpt-5"
      )

    :ok = ModelPolicyAdapter.put_session_model_override(session_key, "anthropic:claude-opus-4.1")

    assert {"anthropic:claude-opus-4.1", :session} =
             ModelPolicyAdapter.resolve_model_hint("default", session_key, chat_id, topic_id)
  end

  test "thinking-only defaults do not resolve as a model hint" do
    chat_id = System.unique_integer([:positive])
    session_key = "telegram:test:model:#{System.unique_integer([:positive])}"

    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", chat_id, nil, "high")

    assert nil == ModelPolicyAdapter.default_model_preference("default", chat_id, nil)

    assert {nil, nil} ==
             ModelPolicyAdapter.resolve_model_hint("default", session_key, chat_id, nil)

    assert "high" == ModelPolicyAdapter.default_thinking_preference("default", chat_id, nil)
  end

  test "setting a model preserves an existing thinking override" do
    chat_id = System.unique_integer([:positive])

    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", chat_id, nil, "high")
    :ok = ModelPolicyAdapter.put_default_model_preference("default", chat_id, nil, "openai:gpt-5")

    assert "openai:gpt-5" == ModelPolicyAdapter.default_model_preference("default", chat_id, nil)
    assert "high" == ModelPolicyAdapter.default_thinking_preference("default", chat_id, nil)
  end

  test "clearing a thinking-only override removes the placeholder policy" do
    chat_id = System.unique_integer([:positive])

    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", chat_id, nil, "high")

    assert true == ModelPolicyAdapter.clear_default_thinking_preference("default", chat_id, nil)
    assert nil == ModelPolicyAdapter.default_thinking_preference("default", chat_id, nil)
    assert nil == ModelPolicyAdapter.default_model_preference("default", chat_id, nil)
    assert nil == ModelPolicy.get(ModelPolicyAdapter.route_for("default", chat_id, nil))
  end

  test "resolve_thinking_hint reports chat scope when only a chat default exists" do
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])

    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", chat_id, nil, "low")

    assert {"low", :chat} = ModelPolicyAdapter.resolve_thinking_hint("default", chat_id, topic_id)
  end

  test "resolve_thinking_hint prefers topic overrides over chat defaults" do
    chat_id = System.unique_integer([:positive])
    topic_id = System.unique_integer([:positive])

    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", chat_id, nil, "low")
    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", chat_id, topic_id, "high")

    assert {"high", :topic} =
             ModelPolicyAdapter.resolve_thinking_hint("default", chat_id, topic_id)
  end

  test "format_thinking_line reports the effective scope" do
    assert "high (topic default)" = ModelPolicyAdapter.format_thinking_line("high", :topic)
    assert "low (chat default)" = ModelPolicyAdapter.format_thinking_line("low", :chat)
    assert "(default)" = ModelPolicyAdapter.format_thinking_line(nil, nil)
  end
end
