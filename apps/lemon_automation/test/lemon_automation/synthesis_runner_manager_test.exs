defmodule LemonAutomation.SynthesisRunnerManagerTest do
  # async: false — drives the singleton manager process and shared store state.
  use ExUnit.Case, async: false

  alias LemonAutomation.SynthesisMetrics
  alias LemonAutomation.SynthesisRunner
  alias LemonAutomation.SynthesisRunnerManager

  @pid_key {__MODULE__, :test_pid}

  defmodule BlockingPipeline do
    @moduledoc false
    # Blocks until the test releases it, so the manager's in-flight guard can be
    # observed deterministically.
    def run(_scope, _scope_key, opts) do
      pid = :persistent_term.get({LemonAutomation.SynthesisRunnerManagerTest, :test_pid})
      send(pid, {:pipeline_run, self(), opts})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      {:ok, %{generated: [], skipped: [], total_candidates: 0, latest_doc_ms: nil}}
    end
  end

  setup do
    :persistent_term.put(@pid_key, self())
    agent_id = "synmgr-agent-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      reset_manager()
      SynthesisRunner.delete_state(agent_id)
      SynthesisMetrics.clear()
      :persistent_term.erase(@pid_key)
    end)

    {:ok, agent_id: agent_id}
  end

  defp reset_manager do
    if Process.whereis(SynthesisRunnerManager) do
      :sys.replace_state(SynthesisRunnerManager, fn state ->
        %{state | opts: [], in_flight_ref: nil}
      end)
    end
  end

  defp set_opts(opts) do
    :sys.replace_state(SynthesisRunnerManager, fn state ->
      %{state | opts: opts, in_flight_ref: nil}
    end)
  end

  defp tick_and_sync do
    :ok = SynthesisRunnerManager.tick()
    _ = :sys.get_state(SynthesisRunnerManager)
    :ok
  end

  defp runner_opts(agent_id) do
    [
      enabled: true,
      agent_id: agent_id,
      pipeline_mod: BlockingPipeline,
      active_sessions_fun: fn -> [] end,
      tick_interval_ms: 3_600_000
    ]
  end

  defp await(fun, attempts \\ 150)
  defp await(_fun, 0), do: flunk("condition never became true")

  defp await(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      await(fun, attempts - 1)
    end
  end

  test "the manager is supervised and running" do
    assert is_pid(Process.whereis(SynthesisRunnerManager))
  end

  test "a tick spawns exactly one pass and the in-flight guard blocks a second", %{
    agent_id: agent_id
  } do
    set_opts(runner_opts(agent_id))

    tick_and_sync()
    assert_receive {:pipeline_run, task_pid, run_opts}, 2_000
    assert Keyword.get(run_opts, :opt_in) == true

    assert is_reference(:sys.get_state(SynthesisRunnerManager).in_flight_ref)

    # Second tick while a pass is in flight must not start another one.
    tick_and_sync()
    refute_receive {:pipeline_run, _, _}, 200

    send(task_pid, :release)
  end

  test ":DOWN from the finished task clears the in-flight guard", %{agent_id: agent_id} do
    set_opts(runner_opts(agent_id))

    tick_and_sync()
    assert_receive {:pipeline_run, task_pid, _opts}, 2_000

    assert is_reference(:sys.get_state(SynthesisRunnerManager).in_flight_ref)

    send(task_pid, :release)

    await(fn -> is_nil(:sys.get_state(SynthesisRunnerManager).in_flight_ref) end)
  end

  test "active sessions defer the pass", %{agent_id: agent_id} do
    set_opts(Keyword.put(runner_opts(agent_id), :active_sessions_fun, fn -> [:busy] end))

    tick_and_sync()
    refute_receive {:pipeline_run, _, _}, 200
    assert is_nil(:sys.get_state(SynthesisRunnerManager).in_flight_ref)
  end

  test "active-session query failures fail closed without launching work", %{agent_id: agent_id} do
    failing_queries = [
      fn -> {:error, :unavailable} end,
      fn -> raise "registry unavailable" end,
      fn -> exit(:registry_unavailable) end
    ]

    Enum.each(failing_queries, fn active_sessions_fun ->
      set_opts(Keyword.put(runner_opts(agent_id), :active_sessions_fun, active_sessions_fun))

      tick_and_sync()
      refute_receive {:pipeline_run, _, _}, 100
      assert is_nil(:sys.get_state(SynthesisRunnerManager).in_flight_ref)
    end)
  end

  test "a disabled runner never spawns a pass", %{agent_id: agent_id} do
    set_opts(Keyword.put(runner_opts(agent_id), :enabled, false))

    tick_and_sync()
    refute_receive {:pipeline_run, _, _}, 200
    assert is_nil(:sys.get_state(SynthesisRunnerManager).in_flight_ref)
  end

  test "the interval gate keeps a recent pass from re-running", %{agent_id: agent_id} do
    now = LemonCore.Clock.now_ms()
    SynthesisRunner.put_state(agent_id, %{watermark_ms: nil, last_run_at_ms: now})

    set_opts(runner_opts(agent_id))

    tick_and_sync()
    refute_receive {:pipeline_run, _, _}, 200
  end
end
