defmodule LemonRouter.RunOwnerTest do
  @moduledoc """
  #728: one run has one owner process. `RunProcess` admits, executes, steers,
  cancels and terminalizes its run itself; nothing else writes its terminal
  record or relays its executor's events.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{Bus, ExecutionCommand, RunStore}
  alias LemonRouter.{RunProcess, TestExecutor}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    handler = "run-owner-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    # `[:lemon, :run, :stop]` is emitted by the process whose RunStore write
    # created the terminal record, and only then.
    :ok =
      :telemetry.attach(
        handler,
        [:lemon, :run, :stop],
        fn _event, _measurements, %{run_id: run_id}, _config ->
          send(test_pid, {:terminal_write, run_id, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "RunCompletion is the only module that writes a terminal run record" do
    root = Path.expand("../../../..", __DIR__)

    writers =
      for app <- ["lemon_router", "lemon_gateway"],
          file <- Path.wildcard(Path.join([root, "apps", app, "lib", "**", "*.ex"])),
          File.read!(file) =~ "RunStore.finalize(",
          do: Path.relative_to(file, root)

    assert writers == ["apps/lemon_router/lib/lemon_router/run_completion.ex"]
  end

  test "an executed run has one owner, which is its only terminal writer" do
    %{run_id: run_id, owner: owner, runner: runner, sink: sink} = start_run()

    # The executor reports straight to the owner: no relay process in between.
    assert sink == owner

    assert [{^owner, _}] = Registry.lookup(LemonRouter.RunRegistry, run_id)
    # The gateway's per-run process and its registry no longer exist.
    refute Process.whereis(LemonGateway.RunRegistry)
    refute Process.whereis(LemonGateway.RunSupervisor)

    TestExecutor.started(runner)
    TestExecutor.delta(runner, "hello")
    assert_receive %LemonCore.Event{type: :delta, payload: %{text: "hello"}}
    TestExecutor.complete(runner, %{answer: "hello"})

    assert_receive %LemonCore.Event{type: :run_completed} = completed
    assert completed.payload.completed.ok == true
    assert_receive {:DOWN, _, :process, ^owner, :normal}

    assert writers(run_id) == [owner]
    refute_receive %LemonCore.Event{type: :run_completed}, 100
    assert {:ok, %{summary: %{completed: %{ok: true}}}} = RunStore.fetch(run_id)
  end

  test "executor loss and cancellation terminalize once, from the owner" do
    %{run_id: lost, owner: lost_owner, runner: lost_runner} = start_run()
    TestExecutor.crash(lost_runner)

    assert_receive %LemonCore.Event{
      type: :run_completed,
      payload: %{completed: %{ok: false, error: %{type: :executor_down, reason: :crashed}}}
    }

    assert_receive {:DOWN, _, :process, ^lost_owner, :normal}
    assert writers(lost) == [lost_owner]

    %{run_id: cancelled, owner: cancel_owner} = start_run()
    :ok = RunProcess.abort(cancel_owner, :user_requested)
    assert_receive {:test_executor_cancel, ^cancelled, ^cancel_owner}

    assert_receive %LemonCore.Event{
      type: :run_completed,
      payload: %{completed: %{ok: false, error: :user_requested}}
    }

    assert_receive {:DOWN, _, :process, ^cancel_owner, :normal}
    assert writers(cancelled) == [cancel_owner]
  end

  test "steer and redirect reach the executor through the owner that completes the run" do
    %{run_id: run_id, owner: owner, runner: runner} = start_run()
    TestExecutor.started(runner)

    :ok = RunProcess.steer(owner, :steer, "steer-sub", "also this", self())
    assert_receive {:test_executor_steer, ^run_id, "also this", ^owner}
    assert_receive {:steer_accepted, "steer-sub"}

    :ok = RunProcess.steer(owner, :redirect, "redirect-sub", "instead this", self())
    assert_receive {:test_executor_redirect, ^run_id, "instead this", ^owner}
    assert_receive {:redirect_accepted, "redirect-sub"}

    TestExecutor.complete(runner)
    assert_receive {:DOWN, _, :process, ^owner, :normal}
    assert writers(run_id) == [owner]
  end

  test "a run that has not started rejects steering" do
    blocker = start_run()
    run_id = "owner-steer-#{System.unique_integer([:positive])}"
    max = elem(LemonRouter.Slots.stats(), 1).max
    others = for _ <- 2..max//1, do: start_run()

    owner = start_owner(run_id)
    :ok = RunProcess.steer(owner, :steer, "early-sub", "too early", self())
    assert_receive {:steer_rejected, "early-sub"}
    refute_received {:test_executor_steer, ^run_id, _, _}

    for %{runner: runner} <- [blocker | others], do: TestExecutor.complete(runner)
    assert_receive {:test_executor_started, ^run_id, runner, _sink}, 2_000
    TestExecutor.complete(runner)
    assert_receive {:DOWN, _, :process, ^owner, :normal}, 2_000
  end

  defp start_run do
    run_id = "owner-#{System.unique_integer([:positive])}"
    owner = start_owner(run_id)
    assert_receive {:test_executor_started, ^run_id, runner, sink}, 2_000
    %{run_id: run_id, owner: owner, runner: runner, sink: sink}
  end

  defp start_owner(run_id) do
    session_key = "agent:test:main:owner-#{System.unique_integer([:positive])}"
    Bus.subscribe(Bus.run_topic(run_id))

    command = %ExecutionCommand{
      run_id: run_id,
      session_key: session_key,
      prompt: "hi",
      conversation_key: {:session, session_key},
      meta: %{test_pid: self()}
    }

    {:ok, owner} =
      DynamicSupervisor.start_child(
        LemonRouter.RunSupervisor,
        {RunProcess,
         run_id: run_id,
         session_key: session_key,
         execution_request: command,
         executor: TestExecutor}
      )

    Process.monitor(owner)
    owner
  end

  defp writers(run_id) do
    Process.sleep(50)

    collect_writers(run_id, [])
  end

  defp collect_writers(run_id, acc) do
    receive do
      {:terminal_write, ^run_id, pid} -> collect_writers(run_id, [pid | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
