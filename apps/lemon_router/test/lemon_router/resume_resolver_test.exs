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

  test "prefers explicit structured resume", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "claude", last_resume_token: "stale"})

    assert {
             %ResumeToken{engine: "codex", value: "thread_123"},
             "codex"
           } =
             ResumeResolver.resolve(
               %ResumeToken{engine: "codex", value: "thread_123"},
               session_key,
               nil,
               %{}
             )
  end

  test "uses auto resume from chat state when compatible", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "codex", last_resume_token: "thread_auto"})

    assert {
             %ResumeToken{engine: "codex", value: "thread_auto"},
             "codex"
           } = ResumeResolver.resolve(nil, session_key, "codex", %{})
  end

  test "does not auto resume when disabled in meta", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "codex", last_resume_token: "thread_auto"})

    assert {nil, "codex"} =
             ResumeResolver.resolve(nil, session_key, "codex", %{disable_auto_resume: true})
  end

  test "does not auto resume when engine is incompatible", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "codex", last_resume_token: "thread_auto"})

    assert {nil, "claude"} = ResumeResolver.resolve(nil, session_key, "claude", %{})
  end
end
