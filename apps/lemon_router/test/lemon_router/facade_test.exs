defmodule LemonRouter.FacadeTest do
  @moduledoc """
  The facade is what other apps are allowed to use, so its contract has to hold
  both when the router is running and when it isn't — the callers it replaced
  each carried their own `Process.whereis` guard and rescue clauses.
  """

  use ExUnit.Case, async: false

  describe "with the router running" do
    test "available?/0 is true" do
      assert LemonRouter.available?()
    end

    test "counts/0 reflects a newly supervised run without changing other counters" do
      before = LemonRouter.counts()

      {:ok, pid} =
        DynamicSupervisor.start_child(
          LemonRouter.RunSupervisor,
          {Task, fn -> receive do: (:stop -> :ok) end}
        )

      on_exit(fn -> DynamicSupervisor.terminate_child(LemonRouter.RunSupervisor, pid) end)

      assert LemonRouter.counts() == %{before | active: before.active + 1}
    end

    test "active_runs/0 returns run summaries without leaking pids" do
      assert {:ok, runs} = LemonRouter.active_runs()

      assert is_list(runs)

      for run <- runs do
        assert is_binary(run.run_id)
        assert Map.has_key?(run, :session_key)
        assert Map.has_key?(run, :agent_id)
        assert Map.has_key?(run, :engine)
        assert Map.has_key?(run, :started_at_ms)
        refute Map.has_key?(run, :pid)
      end
    end

    test "enumerating a real active run returns metadata without terminating it" do
      run_id = "facade-live-#{System.unique_integer([:positive])}"
      session_key = "agent:facade-test:main"

      command = %LemonCore.ExecutionCommand{
        run_id: run_id,
        session_key: session_key,
        conversation_key: {:session, session_key},
        prompt: "private prompt that is not management metadata",
        meta: %{agent_id: "facade-test", private: "private metadata"}
      }

      pid =
        start_supervised!(
          {LemonRouter.RunProcess,
           run_id: run_id,
           session_key: session_key,
           execution_request: command,
           submit_to_gateway?: false}
        )

      ref = Process.monitor(pid)
      assert {:ok, runs} = LemonRouter.active_runs()

      assert %{
               run_id: ^run_id,
               session_key: ^session_key,
               agent_id: "facade-test",
               engine: "lemon",
               started_at_ms: started
             } =
               Enum.find(runs, &(&1.run_id == run_id))

      assert is_integer(started)
      assert Process.alive?(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 50
      refute inspect(LemonRouter.active_runs()) =~ "private"
    end

    test "metadata timeout leaves a busy active run alive and inspectable" do
      run_id = "facade-busy-#{System.unique_integer([:positive])}"
      session_key = "agent:facade-busy:main"

      command = %LemonCore.ExecutionCommand{
        run_id: run_id,
        session_key: session_key,
        conversation_key: {:session, session_key},
        prompt: "hold"
      }

      pid =
        start_supervised!(
          {LemonRouter.RunProcess,
           run_id: run_id,
           session_key: session_key,
           execution_request: command,
           submit_to_gateway?: false}
        )

      :ok = :sys.suspend(pid)

      try do
        started = System.monotonic_time(:millisecond)
        assert {:ok, runs} = LemonRouter.active_runs()

        assert %{run_id: ^run_id, started_at_ms: nil} =
                 Enum.find(runs, &(&1.run_id == run_id))

        assert System.monotonic_time(:millisecond) - started < 1_000
        assert Process.alive?(pid)
      after
        :sys.resume(pid)
      end

      assert %{engine: "lemon"} = GenServer.call(pid, :get_metadata)
      assert Process.alive?(pid)
    end

    test "an unresponsive controller cannot turn an empty registry into an idle snapshot" do
      pid = Process.whereis(LemonRouter.RunOrchestrator)
      :ok = :sys.suspend(pid)

      try do
        assert {:error, :query_failed} = LemonRouter.active_runs()
      after
        :sys.resume(pid)
      end
    end

    test "active_run_count/0 counts supervised runs" do
      before = LemonRouter.active_run_count()

      {:ok, pid} =
        DynamicSupervisor.start_child(
          LemonRouter.RunSupervisor,
          {Task, fn -> receive do: (:stop -> :ok) end}
        )

      on_exit(fn -> DynamicSupervisor.terminate_child(LemonRouter.RunSupervisor, pid) end)

      assert LemonRouter.active_run_count() == before + 1
      assert :ok = DynamicSupervisor.terminate_child(LemonRouter.RunSupervisor, pid)
      assert LemonRouter.active_run_count() == before
    end

    test "run_active?/1 is false for an unknown run and for non-binaries" do
      refute LemonRouter.run_active?("run_definitely_not_started")
      refute LemonRouter.run_active?(nil)
      refute LemonRouter.run_active?(:not_a_run_id)
    end
  end

  describe "with the router down" do
    setup do
      # Callers outside lemon_router may load before/after the router app; the
      # facade has to degrade rather than raise.
      :ok = Application.stop(:lemon_router)
      on_exit(fn -> {:ok, _} = Application.ensure_all_started(:lemon_router) end)
      :ok
    end

    test "reports authoritative reads unavailable instead of idle" do
      refute LemonRouter.available?()
      assert LemonRouter.active_runs() == {:error, :unavailable}
      assert LemonRouter.active_run_count() == 0
      refute LemonRouter.run_active?("run_1")

      assert LemonRouter.counts() == %{
               active: nil,
               queued: nil,
               completed_today: nil,
               failed_today: nil
             }
    end
  end
end
