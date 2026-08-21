defmodule LemonRouter.ResumeResolverTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ChatStateStore, ResumeToken}
  alias LemonRouter.ResumeResolver

  setup do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = ChatStateStore.delete(session_key)
    end)

    {:ok, session_key: session_key}
  end

  test "prefers an explicit native resume token", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "codex", last_resume_token: "stale"})

    assert {:ok, %ResumeToken{engine: "lemon", value: "thread_123"}, :explicit} =
             ResumeResolver.resolve(
               %ResumeToken{engine: "lemon", value: "thread_123"},
               session_key
             )
  end

  test "rejects an explicit resume token for a retired engine", %{session_key: session_key} do
    assert {:error, {:unsupported_resume_engine, "codex", message}} =
             ResumeResolver.resolve(
               %ResumeToken{engine: "codex", value: "thread_123"},
               session_key
             )

    assert message =~ ~s(native "lemon" engine)
  end

  test "uses native auto resume from chat state", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "lemon", last_resume_token: "thread_auto"})

    assert {:ok, %ResumeToken{engine: "lemon", value: "thread_auto"}, :auto} =
             ResumeResolver.resolve(nil, session_key)
  end

  test "does not auto resume when disabled in meta", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "lemon", last_resume_token: "thread_auto"})

    assert {:ok, nil, nil} =
             ResumeResolver.resolve(nil, session_key, %{disable_auto_resume: true})
  end

  test "ignores stale non-native auto state without deleting it", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "claude", last_resume_token: "thread_auto"})

    assert {:ok, nil, nil} = ResumeResolver.resolve(nil, session_key)

    assert %{last_engine: "claude", last_resume_token: "thread_auto"} =
             ChatStateStore.get(session_key)
  end
end
