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

  defmodule RaisingPresentation do
    def finalize_run(_session, _channel, _run_id, _opts), do: raise("presentation crash")
  end

  defmodule RecoveringPresentation do
    def finalize_run(_session, _channel, run_id, opts) do
      send(
        self(),
        {:replayed_presentation, run_id, opts[:final_text], opts[:meta][:durable_terminal]}
      )

      :ok
    end
  end

  test "a presentation crash is not another execution terminal" do
    old_coalescer = Application.get_env(:lemon_router, :stream_coalescer)
    Application.put_env(:lemon_router, :stream_coalescer, RaisingPresentation)

    on_exit(fn ->
      if old_coalescer,
        do: Application.put_env(:lemon_router, :stream_coalescer, old_coalescer),
        else: Application.delete_env(:lemon_router, :stream_coalescer)
    end)

    run_id = "run-presentation-#{System.unique_integer([:positive])}"

    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "completion-test",
        channel_id: "telegram",
        account_id: "test",
        peer_kind: :dm,
        peer_id: "123"
      })

    command = %ExecutionCommand{
      run_id: run_id,
      session_key: session_key,
      conversation_key: {:session, session_key},
      prompt: "hello",
      meta: %{test_pid: self()}
    }

    :ok = Bus.subscribe(Bus.run_topic(run_id))

    assert {:ok, owner} =
             LemonRouter.RunProcess.start_link(%{
               execution_request: command,
               run_id: run_id,
               session_key: session_key,
               executor: LemonRouter.TestExecutor
             })

    Process.unlink(owner)
    monitor = Process.monitor(owner)
    assert_receive {:test_executor_started, ^run_id, _runner, ^owner}
    completed = %{ok: true, answer: "committed"}

    summary = %{
      run_id: run_id,
      session_key: session_key,
      completed: completed,
      meta: %{router_owned: true}
    }

    assert :ok = RunStore.finalize(run_id, summary)

    assert :ok =
             LemonCore.TerminalOutbox.publish(
               run_id,
               LemonCore.TerminalOutbox.event(run_id, summary)
             )

    assert_receive {:DOWN, ^monitor, :process, ^owner, reason}
    assert reason != :normal
    refute_receive %Event{type: :run_failed}, 100
    assert {:ok, %{status: :completed}} = LemonCore.TerminalOutbox.decision(run_id)
    assert {:ok, %{presentation: :failed}} = LemonCore.TerminalOutbox.pending(run_id)
    event_types = Enum.map(Store.list_introspection_events(run_id: run_id), & &1.event_type)
    assert :answer_presentation_failed in event_types
    refute :run_failed in event_types

    Application.put_env(:lemon_router, :stream_coalescer, RecoveringPresentation)
    assert :ok = LemonCore.TerminalOutbox.repair_delivery(run_id)
    assert_receive {:replayed_presentation, ^run_id, "committed", true}
    assert {:ok, %{state: :not_pending}} = LemonCore.TerminalOutbox.delivery_status(run_id)
    assert :ok = LemonCore.TerminalOutbox.repair_delivery(run_id)
    refute_receive {:replayed_presentation, ^run_id, _, _}, 100
  end

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
    :ok = Bus.subscribe(Bus.run_done_topic(run_id))
    attempt_id = "#{run_id}:committed"

    committed = %{
      run_id: run_id,
      session_key: command.session_key,
      attempt_id: attempt_id,
      completed: %{run_id: run_id, ok: true, answer: "earlier committed completion"}
    }

    assert :ok = RunStore.finalize(run_id, committed)

    contender = Task.async(fn -> LemonCore.TerminalOutbox.publish(run_id, synthetic) end)

    assert {:already_finalized,
            %Event{payload: %RunCompleted{completed: %{ok: true} = completed}}} =
             RunCompletion.finalize(command, synthetic, [])

    assert completed.answer == "earlier committed completion"

    assert_receive %Event{
      type: :run_completed,
      meta: %{event_id: event_id, attempt_id: ^attempt_id},
      payload: %{completed: %{ok: true}}
    }

    assert event_id == "run:#{byte_size(run_id)}:#{run_id}:#{attempt_id}:2"

    assert :ok = Task.await(contender)
    assert :ok = RunCompletion.publish(command, synthetic)
    refute_receive %Event{type: :run_completed}, 200
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
      meta: %{test_pid: self()}
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

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    refute_receive %Event{type: :run_completed}
    refute_received {:test_executor_started, ^run_id, _, _}
    assert {:ok, %{summary: ^committed}} = RunStore.fetch(run_id)
  end

  defp synthetic_failure do
    run_id = "run-completion-#{System.unique_integer([:positive])}"
    command = %ExecutionCommand{run_id: run_id, session_key: "completion-test", prompt: ""}

    event =
      Event.new(
        :run_completed,
        RunCompleted.new(%{
          completed:
            Completion.new(%{ok: false, error: %{type: :executor_down, reason: :killed}}),
          duration_ms: nil
        }),
        %{run_id: run_id, synthetic: true}
      )

    {command, event}
  end
end
