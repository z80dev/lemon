defmodule LemonRouter.RunProcess.CompactionTriggerTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Event, ExecutionCommand}
  alias LemonRouter.PendingCompactionStore
  alias LemonRouter.RunProcess.CompactionTrigger

  setup do
    session_key = "compaction:#{System.unique_integer([:positive])}"
    old_compaction_config = Application.get_env(:lemon_router, :compaction)

    on_exit(fn ->
      _ = PendingCompactionStore.delete(session_key)

      if is_nil(old_compaction_config) do
        Application.delete_env(:lemon_router, :compaction)
      else
        Application.put_env(:lemon_router, :compaction, old_compaction_config)
      end
    end)

    %{session_key: session_key}
  end

  test "uses the resolved model context window and preserves marker metadata", %{
    session_key: session_key
  } do
    Application.put_env(:lemon_router, :compaction, %{
      enabled: true,
      context_window_tokens: nil,
      reserve_tokens: 16_384,
      trigger_ratio: 0.9
    })

    state = state(session_key, "gpt-4o")
    event = completed_event(state.run_id, session_key, 120_000)

    assert :ok = CompactionTrigger.maybe_mark_pending_compaction_near_limit(state, event)

    assert %{
             reason: "near_limit",
             session_key: ^session_key,
             input_tokens: 120_000,
             threshold_tokens: 111_616,
             context_window_tokens: 128_000,
             token_source: "usage"
           } = PendingCompactionStore.get(session_key)
  end

  test "does not infer a context window from the completed engine", %{session_key: session_key} do
    Application.put_env(:lemon_router, :compaction, %{
      enabled: true,
      context_window_tokens: nil,
      reserve_tokens: 16_384,
      trigger_ratio: 0.9
    })

    state = state(session_key, "not-a-configured-model")
    event = completed_event(state.run_id, session_key, 400_000, "codex")

    assert :ok = CompactionTrigger.maybe_mark_pending_compaction_near_limit(state, event)
    assert PendingCompactionStore.get(session_key) == nil
  end

  defp state(session_key, model) do
    run_id = "run_#{System.unique_integer([:positive])}"

    %{
      run_id: run_id,
      session_key: session_key,
      execution_request: %ExecutionCommand{
        run_id: run_id,
        session_key: session_key,
        prompt: "test",
        meta: %{model: model}
      }
    }
  end

  defp completed_event(run_id, session_key, input_tokens, engine \\ nil) do
    Event.new(
      :run_completed,
      %{
        completed: %{
          ok: true,
          usage: %{input_tokens: input_tokens},
          engine: engine
        }
      },
      %{run_id: run_id, session_key: session_key}
    )
  end
end
