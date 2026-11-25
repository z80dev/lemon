defmodule LemonRouter.RunProcess.CompactionTriggerTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Event, ExecutionCommand}
  alias LemonCore.Events.Usage
  alias LemonRouter.PendingCompactionStore
  alias LemonRouter.RunProcess.CompactionTrigger

  # context_window 100_000, reserve 16_384, ratio 0.9 -> threshold min(83_616, 90_000).
  @threshold 83_616

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
    event = completed_event(state.run_id, session_key, %Usage{context_tokens: 120_000})

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

    event =
      completed_event(state.run_id, session_key, %Usage{context_tokens: 400_000}, "codex")

    assert :ok = CompactionTrigger.maybe_mark_pending_compaction_near_limit(state, event)
    assert PendingCompactionStore.get(session_key) == nil
  end

  describe "threshold input" do
    setup do
      Application.put_env(:lemon_router, :compaction, %{
        enabled: true,
        context_window_tokens: 100_000,
        reserve_tokens: 16_384,
        trigger_ratio: 0.9
      })

      :ok
    end

    test "a five-call run at 20K context does not compact despite 100K cumulative tokens", %{
      session_key: session_key
    } do
      calls = List.duplicate(call(20_000, 0, 0, 500), 5)
      usage = run_usage(calls, context_tokens: 20_500)

      # The regression: the run's cumulative input (100K) crosses the threshold that
      # its context (20K) is nowhere near.
      assert usage.input + usage.cache_read + usage.cache_write == 100_000
      assert usage.input >= @threshold

      for payload <- [usage, Jason.decode!(Jason.encode!(usage))] do
        state = state(session_key, "gpt-4o")
        event = completed_event(state.run_id, session_key, payload)

        assert :ok = CompactionTrigger.maybe_mark_pending_compaction_near_limit(state, event)
        assert PendingCompactionStore.get(session_key) == nil
      end
    end

    test "uses context_tokens when present", %{session_key: session_key} do
      # The last call alone would stay under the threshold; the reported context wins.
      usage = run_usage([call(1_000, 0, 0, 10)], context_tokens: 90_000)

      state = state(session_key, "gpt-4o")

      assert :ok =
               CompactionTrigger.maybe_mark_pending_compaction_near_limit(
                 state,
                 completed_event(state.run_id, session_key, usage)
               )

      assert %{input_tokens: 90_000, threshold_tokens: @threshold, token_source: "usage"} =
               PendingCompactionStore.get(session_key)
    end

    test "falls back to the last call's cache-inclusive input without context_tokens", %{
      session_key: session_key
    } do
      state = state(session_key, "gpt-4o")

      # Small earlier calls, large last call: 30_000 + 50_000 + 5_000 crosses.
      crossing = run_usage([call(10_000, 0, 0, 10), call(30_000, 50_000, 5_000, 10)])

      assert :ok =
               CompactionTrigger.maybe_mark_pending_compaction_near_limit(
                 state,
                 completed_event(state.run_id, session_key, crossing)
               )

      assert %{input_tokens: 85_000, token_source: "usage"} =
               PendingCompactionStore.get(session_key)

      PendingCompactionStore.delete(session_key)

      # Large earlier call, small last call: only the last call counts.
      under = run_usage([call(30_000, 50_000, 5_000, 10), call(10_000, 0, 0, 10)])

      assert :ok =
               CompactionTrigger.maybe_mark_pending_compaction_near_limit(
                 state,
                 completed_event(state.run_id, session_key, under)
               )

      assert PendingCompactionStore.get(session_key) == nil
    end

    test "cumulative usage never triggers compaction", %{session_key: session_key} do
      cumulative = %{
        input: 500_000,
        output: 10_000,
        cache_read: 400_000,
        cache_write: 50_000,
        total_tokens: 960_000
      }

      # Neither a context measurement nor a per-call breakdown: only the prompt
      # estimate remains, and the short prompt is far below the threshold.
      for usage <- [
            cumulative,
            Map.new(cumulative, fn {key, value} -> {Atom.to_string(key), value} end),
            # Retired alias spellings are not usage.
            %{input_tokens: 500_000, cache_read_input_tokens: 400_000, prompt_tokens: 900_000},
            # A last call with an unreported component is unknown, not partial.
            run_usage([call(90_000, nil, 0, 10)]) |> Map.merge(cumulative)
          ] do
        state = state(session_key, "gpt-4o")

        assert :ok =
                 CompactionTrigger.maybe_mark_pending_compaction_near_limit(
                   state,
                   completed_event(state.run_id, session_key, usage)
                 )

        assert PendingCompactionStore.get(session_key) == nil
      end
    end
  end

  defp call(input, cache_read, cache_write, output) do
    %Usage{
      input: input,
      cache_read: cache_read,
      cache_write: cache_write,
      output: output,
      total_tokens: Enum.sum(Enum.map([input, cache_read, cache_write, output], &(&1 || 0)))
    }
  end

  # Mirrors the native producer: counters sum every call, occurrences keep each one.
  defp run_usage(calls, opts \\ []) do
    sum = fn key -> calls |> Enum.map(&(Map.fetch!(&1, key) || 0)) |> Enum.sum() end

    %Usage{
      input: sum.(:input),
      output: sum.(:output),
      cache_read: sum.(:cache_read),
      cache_write: sum.(:cache_write),
      total_tokens: sum.(:total_tokens),
      context_tokens: Keyword.get(opts, :context_tokens),
      occurrences: Enum.map(calls, &%{model: "gpt-4o", provider: :openai, at_ms: 1, usage: &1})
    }
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

  defp completed_event(run_id, session_key, usage, engine \\ nil) do
    Event.new(
      :run_completed,
      %{
        completed: %{
          ok: true,
          usage: usage,
          engine: engine
        }
      },
      %{run_id: run_id, session_key: session_key}
    )
  end
end
