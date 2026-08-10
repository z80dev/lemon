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

    test "counts/0 returns the full shape" do
      counts = LemonRouter.counts()

      assert is_integer(counts.active)
      assert is_integer(counts.queued)
      assert is_integer(counts.completed_today)
    end

    test "active_runs/0 returns run summaries without leaking pids" do
      runs = LemonRouter.active_runs()

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

    test "active_run_count/0 counts supervised runs" do
      assert LemonRouter.active_run_count() >= 0
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

    test "reports nothing active instead of raising" do
      refute LemonRouter.available?()
      assert LemonRouter.active_runs() == []
      assert LemonRouter.active_run_count() == 0
      refute LemonRouter.run_active?("run_1")
      assert LemonRouter.counts() == %{active: 0, queued: 0, completed_today: 0}
    end
  end
end
