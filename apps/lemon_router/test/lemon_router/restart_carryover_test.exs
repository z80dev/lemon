defmodule LemonRouter.RestartCarryoverTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ExecutionCommand, RunRequest, Store}
  alias LemonRouter.{RestartCarryover, SessionCoordinator, Submission}

  # Stands in for RunProcess: registered like one, and answers a restart
  # suspension the way the test chooses.
  defmodule SuspendableRun do
    use GenServer

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id]},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts,
        name:
          {:via, Registry,
           {LemonRouter.RunRegistry, opts[:run_id], %{session_key: opts[:session_key]}}}
      )
    end

    @impl true
    def init(opts) do
      send(opts[:test_pid], {:started, opts[:run_id]})
      {:ok, Map.new(opts)}
    end

    @impl true
    def handle_cast({:suspend_for_restart, reply_to, mode}, state) do
      outcome = Map.fetch!(state.outcomes, mode)

      if outcome == :ignore do
        {:noreply, state}
      else
        send(reply_to, {:restart_suspended, state.run_id, outcome, ["bash: make deploy"]})
        {:stop, :normal, state}
      end
    end

    def handle_cast({:abort, _reason}, state), do: {:stop, :normal, state}
  end

  setup do
    {:ok, run_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    # Only this test's coordinators may take part in the drain.
    {:ok, coordinators} = DynamicSupervisor.start_link(strategy: :one_for_one)
    original = Process.whereis(LemonRouter.SessionCoordinatorSupervisor)
    if original, do: Process.unregister(LemonRouter.SessionCoordinatorSupervisor)
    Process.register(coordinators, LemonRouter.SessionCoordinatorSupervisor)
    clear_carryover()

    on_exit(fn ->
      if Process.whereis(LemonRouter.SessionCoordinatorSupervisor),
        do: Process.unregister(LemonRouter.SessionCoordinatorSupervisor)

      if original && Process.alive?(original),
        do: Process.register(original, LemonRouter.SessionCoordinatorSupervisor)

      RestartCarryover.reset()
      clear_carryover()
    end)

    {:ok, run_supervisor: run_supervisor}
  end

  defp clear_carryover do
    {:ok, rows} = Store.fetch_all(RestartCarryover.table())
    Enum.each(rows, fn {key, _} -> Store.delete(RestartCarryover.table(), key) end)
  end

  test "a clean suspension continues the session and replays queued work in order", ctx do
    key = conversation()
    outcomes = %{boundary: :clean, now: :clean}

    :ok = submit(key, "Fix the bug", outcomes, ctx.run_supervisor)
    assert_receive {:started, active_id}
    :ok = submit(key, "Then add a test", outcomes, ctx.run_supervisor)

    assert {:ok, summary} = RestartCarryover.drain(:work, drain_ctx(0, 2_000))
    assert %{clean: 1, uncertain: 0, carried: 1, skipped: 0} = summary
    assert RestartCarryover.sealed?()

    assert {:error, :runtime_stopping} =
             submit(key, "Too late", outcomes, ctx.run_supervisor)

    assert {:ok, [{_key, %{items: [continue, replay]}}]} =
             Store.fetch_all(RestartCarryover.table())

    assert %{kind: :continue, outcome: :clean, interrupted_run_id: ^active_id} = continue
    assert continue.request.prompt =~ "Continue the task from where you stopped"
    # Quoted in case the run stopped before the journal recorded the request.
    assert continue.request.prompt =~ "The interrupted request was:\n> Fix the bug"
    assert continue.request.meta.restart_continuation == true
    refute Map.has_key?(continue.request.meta, :disable_auto_resume)
    refute continue.request.run_id == active_id

    assert %{kind: :replay, outcome: :queued} = replay
    assert replay.request.prompt == "Then add a test"

    test_pid = self()

    submit_fun = fn request ->
      send(test_pid, {:submitted, request})
      {:ok, request.run_id}
    end

    assert {:ok, %{submitted: 2, rejected: 0, pending: 0}} =
             RestartCarryover.replay(submit: submit_fun)

    continue_run_id = continue.request.run_id
    replay_run_id = replay.request.run_id
    assert_received {:submitted, %RunRequest{run_id: ^continue_run_id}}
    assert_received {:submitted, %RunRequest{run_id: ^replay_run_id, prompt: "Then add a test"}}
    assert {:ok, []} = Store.fetch_all(RestartCarryover.table())
  end

  test "a run still inside an action at the deadline continues as uncertain", ctx do
    key = conversation()

    :ok = submit(key, "Deploy it", %{boundary: :ignore, now: :uncertain}, ctx.run_supervisor)
    assert_receive {:started, _run_id}

    assert {:ok, %{uncertain: 1, carried: 1}} =
             RestartCarryover.drain(:work, drain_ctx(0, 3_500))

    assert {:ok, [{_key, %{items: [continue]}}]} = Store.fetch_all(RestartCarryover.table())
    assert continue.outcome == :uncertain
    assert continue.request.prompt =~ "`bash: make deploy` was still running"
    assert continue.request.prompt =~ "Do not repeat it automatically"
    assert continue.request.prompt =~ "> Deploy it"
  end

  test "a run the runtime never started is replayed with its original prompt", ctx do
    key = conversation()

    :ok =
      submit(key, "Summarize", %{boundary: :not_started, now: :not_started}, ctx.run_supervisor)

    assert_receive {:started, _run_id}

    assert {:ok, %{not_started: 1, carried: 1}} =
             RestartCarryover.drain(:work, drain_ctx(0, 2_000))

    assert {:ok, [{_key, %{items: [%{kind: :replay} = item]}}]} =
             Store.fetch_all(RestartCarryover.table())

    assert item.request.prompt == "Summarize"
  end

  test "requests holding process-bound terms are skipped, not persisted", ctx do
    key = conversation()

    :ok =
      submit(key, "Reply to me", %{boundary: :clean, now: :clean}, ctx.run_supervisor,
        meta: %{reply_to: self()}
      )

    assert_receive {:started, _run_id}
    assert {:ok, %{skipped: 1, carried: 0}} = RestartCarryover.drain(:work, drain_ctx(0, 2_000))
    assert {:ok, []} = Store.fetch_all(RestartCarryover.table())
  end

  test "an unknown replay outcome keeps the item under its fixed run ID for the next boot" do
    request = %RunRequest{
      session_key: "agent:test:main:replay",
      prompt: "hi",
      run_id: "run_fixed"
    }

    :ok =
      Store.put(RestartCarryover.table(), {1, 0}, %{
        items: [%{kind: :replay, outcome: :queued, request: request}],
        version: 1,
        recorded_at_ms: 1,
        attempts: 0
      })

    assert {:ok, %{pending: 1}} =
             RestartCarryover.replay(submit: fn _ -> {:error, :outcome_unknown} end)

    assert {:ok, [{_, %{attempts: 1, items: [%{request: %{run_id: "run_fixed"}}]}}]} =
             Store.fetch_all(RestartCarryover.table())

    assert {:ok, %{submitted: 1}} = RestartCarryover.replay(submit: &{:ok, &1.run_id})
    assert {:ok, []} = Store.fetch_all(RestartCarryover.table())
  end

  defp submit(key, prompt, outcomes, run_supervisor, opts \\ []) do
    run_id = "run_#{System.unique_integer([:positive])}"
    meta = Keyword.get(opts, :meta, %{disable_auto_resume: true})

    request = %RunRequest{
      run_id: run_id,
      session_key: elem(key, 1),
      prompt: prompt,
      origin: :channel,
      meta: meta
    }

    SessionCoordinator.submit(
      key,
      Submission.new!(%{
        run_id: run_id,
        session_key: elem(key, 1),
        conversation_key: key,
        queue_mode: :collect,
        execution_request: %ExecutionCommand{
          run_id: run_id,
          session_key: elem(key, 1),
          prompt: prompt,
          conversation_key: key,
          meta: %{}
        },
        run_supervisor: run_supervisor,
        run_process_module: SuspendableRun,
        run_process_opts: %{test_pid: self(), outcomes: outcomes, session_key: elem(key, 1)},
        request: request
      })
    )
  end

  defp conversation, do: {:session, "agent:test:main:#{System.unique_integer([:positive])}"}

  defp drain_ctx(grace_ms, timeout_ms) do
    now = System.monotonic_time(:millisecond)

    %{
      reason: :test,
      started_at_ms: now,
      grace_deadline_ms: now + grace_ms,
      deadline_ms: now + timeout_ms
    }
  end
end
