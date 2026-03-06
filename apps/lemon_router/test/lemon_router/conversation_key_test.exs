defmodule LemonRouter.ConversationKeyTest do
  use ExUnit.Case, async: true

  alias LemonCore.ResumeToken
  alias LemonRouter.ConversationKey

  test "uses resume token when present" do
    assert ConversationKey.resolve("agent:test:main", %ResumeToken{
             engine: "codex",
             value: "thread_123"
           }) == {:resume, "codex", "thread_123"}
  end

  test "falls back to session key when resume is absent" do
    assert ConversationKey.resolve("agent:test:main", nil) == {:session, "agent:test:main"}
  end

  test "normalizes map resume tokens" do
    assert ConversationKey.resolve("agent:test:main", %{engine: "claude", value: "abc"}) ==
             {:resume, "claude", "abc"}
  end
end
