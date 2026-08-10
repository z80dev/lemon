defmodule LemonRouter.RunProcess.ChatStateOwnershipTest do
  @moduledoc """
  The router owns resume-token persistence.

  The gateway used to write chat state from its own finalization path while the
  router cleared it on context overflow from the same completion event — two
  apps writing one key. These tests pin the single-writer behaviour: the router
  writes on completion, and still clears on overflow instead of writing.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{ChatState, ChatStateStore, Event, ResumeToken}
  alias LemonRouter.RunProcess.CompactionTrigger

  setup do
    session_key = "agent:chat_state_owner_#{System.unique_integer([:positive])}:main"
    on_exit(fn -> ChatStateStore.delete(session_key) end)
    %{session_key: session_key, state: %{session_key: session_key, run_id: "run_1"}}
  end

  defp completed_event(fields) do
    %Event{
      type: :run_completed,
      ts_ms: System.system_time(:millisecond),
      payload: %{completed: Map.merge(%{__event__: :completed, ok: true}, fields)}
    }
  end

  describe "maybe_store_chat_state/2" do
    test "writes the resume token exactly once per completed run", %{
      session_key: key,
      state: state
    } do
      event = completed_event(%{resume: %ResumeToken{engine: "codex", value: "thread-1"}})

      assert :ok = CompactionTrigger.maybe_store_chat_state(state, event)

      assert %ChatState{last_engine: "codex", last_resume_token: "thread-1"} =
               ChatStateStore.get(key)
    end

    test "a second completion overwrites rather than accumulating", %{
      session_key: key,
      state: state
    } do
      :ok =
        CompactionTrigger.maybe_store_chat_state(
          state,
          completed_event(%{resume: %ResumeToken{engine: "codex", value: "thread-1"}})
        )

      :ok =
        CompactionTrigger.maybe_store_chat_state(
          state,
          completed_event(%{resume: %ResumeToken{engine: "claude", value: "thread-2"}})
        )

      assert %ChatState{last_engine: "claude", last_resume_token: "thread-2"} =
               ChatStateStore.get(key)
    end

    test "does not write when the run carried no resume token", %{
      session_key: key,
      state: state
    } do
      assert :ok = CompactionTrigger.maybe_store_chat_state(state, completed_event(%{}))
      assert ChatStateStore.get(key) == nil
    end

    test "does not write on context overflow — that run's state is being cleared", %{
      session_key: key,
      state: state
    } do
      event =
        completed_event(%{
          ok: false,
          error: "context_length_exceeded",
          resume: %ResumeToken{engine: "codex", value: "thread-1"}
        })

      assert :ok = CompactionTrigger.maybe_store_chat_state(state, event)
      assert ChatStateStore.get(key) == nil
    end
  end

  describe "overflow still clears" do
    test "maybe_reset_resume_on_context_overflow/2 deletes previously stored state", %{
      session_key: key,
      state: state
    } do
      :ok =
        CompactionTrigger.maybe_store_chat_state(
          state,
          completed_event(%{resume: %ResumeToken{engine: "codex", value: "thread-1"}})
        )

      assert %ChatState{} = ChatStateStore.get(key)

      overflow = completed_event(%{ok: false, error: "context_length_exceeded"})
      assert :ok = CompactionTrigger.maybe_reset_resume_on_context_overflow(state, overflow)

      assert ChatStateStore.get(key) == nil
    end
  end
end
