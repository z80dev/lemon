defmodule LemonRouter.RunCompletionTest do
  @moduledoc """
  Router-owned terminalization (executor exit and abort
  synthesis) commits the terminal decision before anyone can observe it
  (#74), and never publishes an outcome that contradicts an earlier committed
  decision (#75).
  """
  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event, ExecutionCommand, RunStore, Store}
  alias LemonCore.Events.{Completion, RunCompleted}
  alias LemonRouter.RunCompletion

  test "the completion is broadcast only after its terminal decision commits" do
    {command, event} = synthetic_failure()
    run_id = command.run_id
    parent = self()

    # Finalize hooks run after the summary is written and before finalize
    # returns: holding one open freezes the owner between commit and publish.
    hook = fn
      %{run_id: ^run_id} ->
        send(parent, {:committed, self()})

        receive do
          :release -> :ok
        after
          2_000 -> :ok
        end

      _other ->
        :ok
    end

    :ok = Store.register_finalize_run_hook(hook)
    on_exit(fn -> Store.unregister_finalize_run_hook(hook) end)
    :ok = Bus.subscribe(Bus.run_topic(run_id))

    publisher = Task.async(fn -> RunCompletion.publish(command, event) end)

    assert_receive {:committed, hook_pid}, 2_000
    assert {:ok, %{summary: %{completed: %{ok: false}}}} = RunStore.fetch(run_id)
    refute_receive %Event{type: :run_completed}, 200

    send(hook_pid, :release)
    assert :ok = Task.await(publisher)

    assert_receive %Event{
                     type: :run_completed,
                     payload: %RunCompleted{completed: %{ok: false, run_id: ^run_id}}
                   },
                   2_000
  end

  test "a storage failure exits the owner without broadcasting a completion" do
    {command, event} = synthetic_failure()
    run_id = command.run_id
    :ok = Bus.subscribe(Bus.run_topic(run_id))

    # A run record finalization rejects is a deterministic persistence failure.
    :ok = Store.put(:runs, run_id, %{events: [], started_at: 0})

    {pid, ref} = spawn_monitor(fn -> RunCompletion.publish(command, event) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :terminal_persistence_failed}, 2_000

    refute_receive %Event{type: :run_completed}, 100
    assert {:ok, record} = RunStore.fetch(run_id)
    refute Map.has_key?(record, :summary)
  end

  test "an earlier committed decision wins and reaches the owner instead of the synthetic one" do
    {command, synthetic} = synthetic_failure()
    run_id = command.run_id
    :ok = Bus.subscribe(Bus.run_topic(run_id))

    committed = %{
      run_id: run_id,
      session_key: command.session_key,
      completed: %{run_id: run_id, ok: true, answer: "earlier committed completion"}
    }

    assert :ok = RunStore.finalize(run_id, committed)

    assert {:already_finalized,
            %Event{payload: %RunCompleted{completed: %{ok: true} = completed}}} =
             RunCompletion.finalize(command, synthetic, [])

    assert :ok = RunCompletion.publish(command, synthetic)
    refute_receive %Event{type: :run_completed}
    assert completed.answer == "earlier committed completion"
    refute_receive %Event{type: :run_completed, payload: %{completed: %{ok: false}}}, 200
    assert {:ok, %{summary: ^committed}} = RunStore.fetch(run_id)
  end

  test "an owner adopts a durable outcome before it starts the executor" do
    run_id = "run-completion-#{System.unique_integer([:positive])}"
    session_key = LemonCore.SessionKey.main("completion-test")

    command = %ExecutionCommand{
      run_id: run_id,
      session_key: nil,
      prompt: "test",
      conversation_key: {:session, "completion-test:#{run_id}"},
      meta: %{}
    }

    # The earlier writer committed this decision but did not broadcast it.
    committed = %{
      run_id: run_id,
      session_key: session_key,
      completed: %{run_id: run_id, ok: true, answer: "committed answer"}
    }

    assert :ok = RunStore.finalize(run_id, committed)
    :ok = Bus.subscribe(Bus.session_topic(session_key))

    assert {:ok, pid} =
             LemonRouter.RunProcess.start_link(%{
               run_id: run_id,
               session_key: session_key,
               execution_request: command,
               executor: LemonRouter.TestExecutor
             })

    ref = Process.monitor(pid)

    assert_receive %Event{
                     type: :run_completed,
                     payload: %{completed: %{ok: true, answer: "committed answer"}}
                   },
                   2_500

    refute_receive %Event{type: :run_completed, payload: %{completed: %{ok: false}}}, 200
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    assert {:ok, %{summary: ^committed}} = RunStore.fetch(run_id)
  end

  defp synthetic_failure do
    run_id = "run-completion-#{System.unique_integer([:positive])}"
    command = %ExecutionCommand{run_id: run_id, session_key: "completion-test", prompt: ""}

    event =
      Event.new(
        :run_completed,
        RunCompleted.new(%{
          completed: Completion.new(%{ok: false, error: %{type: :executor_down, reason: :killed}}),
          duration_ms: nil
        }),
        %{run_id: run_id, synthetic: true}
      )

    {command, event}
  end
end
