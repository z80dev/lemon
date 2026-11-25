Code.require_file("../../../lemon_platform_test/test/support/crash_model.exs", __DIR__)

defmodule LemonRouter.CrashModelTest do
  use ExUnit.Case, async: true

  alias LemonCore.{ExecutionCommand, RunRequest, Store}
  alias LemonPlatformTest.Testing.CrashModel
  alias LemonRouter.{RestartCarryover, SessionState, SessionTransitions, Submission}

  @moduletag :crash_model
  @moduletag :tmp_dir
  @store :router_crash_model_store
  @seed 555_002

  test "FinishOnce keeps terminal ownership and summaries terminal after recovery", %{
    tmp_dir: dir
  } do
    generator =
      StreamData.tuple({
        StreamData.list_of(
          StreamData.member_of([:down, :abort, :cancel, :accepted, :rejected, :successor]),
          min_length: 1,
          max_length: 12
        ),
        StreamData.integer(0..1_000_000)
      })

    for {{operations, selector}, index} <-
          Enum.with_index(CrashModel.samples(generator, @seed)) do
      path = Path.join(dir, "finish-#{index}.journal")
      store = CrashModel.start_store!(@store, path)
      monitor = make_ref()

      state = %SessionState{
        conversation_key: {:session, "model"},
        active: %{run_id: "finished", session_key: "model", pid: self(), mon_ref: monitor}
      }

      {:ok, state, _effects} = SessionTransitions.submit(state, submission("successor"), 0)
      {:ok, state, _effects} = SessionTransitions.active_down(state, self(), monitor, 1)
      assert_terminal(state)
      summary = %{status: :completed, completed_at_ms: 1}
      assert :ok = Store.finalize_run(@store, "finished", summary)
      assert :ok = Store.put(@store, :crash_model, :state, state)
      assert :ok = Store.sync(@store)
      operations = [:successor, :down | operations]

      Enum.reduce(operations, state, fn operation, state ->
        state = transition(state, operation, monitor)
        assert_terminal(state)
        assert :ok = Store.put(@store, :crash_model, :state, state)

        assert {:error, {:already_finalized, "finished"}} =
                 Store.finalize_run(@store, "finished", %{status: :running})

        state
      end)

      CrashModel.crash_cut!(store, path, selector)
      reopened = CrashModel.start_store!(@store, path)
      assert {:ok, recovered} = Store.fetch(@store, :crash_model, :state)
      assert_terminal(recovered)
      assert {:ok, %{summary: ^summary}} = Store.fetch_run(@store, "finished")

      Enum.reduce(operations, recovered, fn operation, state ->
        next = transition(state, operation, monitor)
        assert_terminal(next)
        next
      end)

      CrashModel.crash!(reopened)
    end
  end

  test "ReplayOnce starts one fixed run ID once despite lost replay bookkeeping", %{tmp_dir: dir} do
    generator =
      StreamData.tuple({
        StreamData.list_of(StreamData.member_of([:unknown, :accepted, :crash]),
          min_length: 1,
          max_length: 8
        ),
        StreamData.integer(0..1_000_000)
      })

    for {{operations, selector}, index} <-
          Enum.with_index(CrashModel.samples(generator, @seed + 1)) do
      path = Path.join(dir, "replay-#{index}.journal")
      store = CrashModel.start_store!(@store, path)
      sink = :ets.new(:crash_model_sink, [:set])
      :ets.insert(sink, {:starts, 0})
      run_id = "fixed-#{index}"
      request = %RunRequest{run_id: run_id, session_key: "model", prompt: "execute once"}

      assert :ok =
               Store.put(@store, RestartCarryover.table(), {1, index}, %{
                 items: [%{kind: :replay, outcome: :queued, request: request}],
                 version: 1,
                 recorded_at_ms: 1,
                 attempts: 0
               })

      assert :ok = Store.sync(@store)

      # A start succeeds externally but its acknowledgement and all unsynced
      # replay bookkeeping are lost. The sink survives the simulated VM crash.
      replay(sink, run_id, :unknown)
      CrashModel.crash_cut!(store, path, 0)
      store = CrashModel.start_store!(@store, path)

      store =
        Enum.reduce(operations ++ [:accepted], store, fn
          :crash, store ->
            CrashModel.crash_cut!(store, path, selector)
            CrashModel.start_store!(@store, path)

          outcome, store ->
            replay(sink, run_id, outcome)
            store
        end)

      assert :ets.lookup(sink, :starts) == [{:starts, 1}], "ReplayOnce: duplicate external start"
      assert :ets.lookup(sink, run_id) == [{run_id, true}], "ReplayOnce: lost fixed identity"
      :ets.delete(sink)
      CrashModel.crash!(store)
    end
  end

  defp replay(sink, run_id, outcome) do
    submit = fn request ->
      assert request.run_id == run_id, "ReplayOnce: replay replaced its durable run ID"

      if :ets.insert_new(sink, {request.run_id, true}),
        do: :ets.update_counter(sink, :starts, 1)

      case outcome do
        :unknown -> {:error, :outcome_unknown}
        :accepted -> {:ok, request.run_id}
      end
    end

    assert {:ok, _summary} = RestartCarryover.replay(store: @store, submit: submit)
  end

  defp assert_terminal(state) do
    refute match?(%{run_id: "finished"}, state.active), "FinishOnce: completed run revived"
    refute Enum.any?(state.queue, &(&1.run_id == "finished")), "FinishOnce: completed run queued"
  end

  defp transition(state, :successor, _monitor) do
    case state do
      %SessionState{active: nil, queue: [submission | rest]} ->
        active = %{
          run_id: submission.run_id,
          session_key: "model",
          pid: self(),
          mon_ref: make_ref()
        }

        %SessionState{state | active: active, queue: rest}

      _ ->
        state
    end
  end

  defp transition(state, operation, monitor) do
    previous = state.active

    {:ok, next, _effects} =
      case operation do
        :down -> SessionTransitions.active_down(state, self(), monitor, 2)
        :abort -> SessionTransitions.abort_run(state, "finished", :user_requested)
        :cancel -> SessionTransitions.cancel_session(state, "finished-session", :user_requested)
        :accepted -> SessionTransitions.steer_accepted(state, "finished")
        :rejected -> SessionTransitions.steer_rejected(state, "finished", 2)
      end

    assert next.active == previous, "FinishOnce: late event changed successor ownership"
    next
  end

  defp submission(run_id) do
    Submission.new!(%{
      run_id: run_id,
      session_key: "model",
      conversation_key: {:session, "model"},
      queue_mode: :collect,
      execution_request: %ExecutionCommand{
        run_id: run_id,
        session_key: "model",
        conversation_key: {:session, "model"},
        prompt: "next",
        meta: %{}
      }
    })
  end
end
