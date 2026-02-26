defmodule Ai.ProviderSupervisorTest do
  @moduledoc """
  Tests for Ai.ProviderSupervisor dynamic supervisor.

  Verifies:
  - Supervisor startup and initialization
  - Child process management
  - Dynamic provider addition
  - Error isolation between providers
  - Supervisor restart strategies
  - Integration with ProviderRegistry
  """
  use ExUnit.Case, async: false

  alias Ai.ProviderSupervisor

  # Test GenServer for simulating provider processes
  defmodule TestWorker do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts) do
      {:ok, %{opts: opts, started_at: System.monotonic_time()}}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
    end

    @impl true
    def handle_call(:crash, _from, _state) do
      raise "intentional crash"
    end

    @impl true
    def handle_cast(:crash, _state) do
      raise "intentional crash"
    end
  end

  # Test GenServer that crashes on init
  defmodule CrashingWorker do
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, :crash)
    end

    @impl true
    def init(:crash) do
      {:stop, :intentional_crash}
    end
  end

  # Test GenServer with slow init
  defmodule SlowWorker do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      delay = Keyword.get(opts, :delay, 100)
      GenServer.start_link(__MODULE__, %{delay: delay}, name: name)
    end

    @impl true
    def init(%{delay: delay}) do
      Process.sleep(delay)
      {:ok, %{}}
    end
  end

  # Helper to generate unique names
  defp unique_name do
    :"test_worker_#{System.unique_integer([:positive])}"
  end

  # Helper to clean up test processes
  defp cleanup_child(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      DynamicSupervisor.terminate_child(Ai.ProviderSupervisor, pid)
    end
  end

  defp cleanup_child(_), do: :ok

  # Ensure supervisor is running before each test
  setup do
    # Wait for any prior restart to complete
    Process.sleep(10)

    # Ensure the supervisor is available
    case Process.whereis(Ai.ProviderSupervisor) do
      nil ->
        # Wait a bit longer if not found
        Process.sleep(100)

        assert Process.whereis(Ai.ProviderSupervisor) != nil,
               "ProviderSupervisor should be running"

      pid ->
        assert Process.alive?(pid)
    end

    :ok
  end

  # ============================================================================
  # Supervisor Startup Tests
  # ============================================================================

  describe "supervisor startup" do
    test "supervisor is running after application start" do
      assert pid = Process.whereis(Ai.ProviderSupervisor)
      assert Process.alive?(pid)
    end

    test "supervisor has correct module" do
      pid = Process.whereis(Ai.ProviderSupervisor)
      assert {:registered_name, Ai.ProviderSupervisor} = Process.info(pid, :registered_name)
    end

    test "supervisor can be started with custom name" do
      custom_name = :"custom_supervisor_#{System.unique_integer([:positive])}"
      {:ok, pid} = ProviderSupervisor.start_link(name: custom_name)

      assert Process.whereis(custom_name) == pid
      assert Process.alive?(pid)

      # Cleanup
      GenServer.stop(pid)
    end

    test "supervisor starts with no children" do
      custom_name = :"empty_supervisor_#{System.unique_integer([:positive])}"
      {:ok, pid} = ProviderSupervisor.start_link(name: custom_name)

      children = DynamicSupervisor.which_children(pid)
      assert children == []

      # Cleanup
      GenServer.stop(pid)
    end

    test "supervisor uses one_for_one strategy" do
      # The strategy is set in init/1 - we verify by behavior
      # Start two children, crash one, verify the other survives
      name1 = unique_name()
      name2 = unique_name()

      {:ok, pid1} = start_test_worker(name1)
      {:ok, pid2} = start_test_worker(name2)

      # Crash pid1
      Process.exit(pid1, :kill)
      Process.sleep(50)

      # pid2 should still be alive
      assert Process.alive?(pid2)

      # Cleanup
      cleanup_child(pid2)
    end
  end

  # ============================================================================
  # Child Process Management Tests
  # ============================================================================

  describe "child process management" do
    test "can start a child process" do
      name = unique_name()
      {:ok, pid} = start_test_worker(name)

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert Process.whereis(name) == pid

      cleanup_child(pid)
    end

    test "can start multiple child processes" do
      names = for _ <- 1..5, do: unique_name()
      pids = for name <- names, do: elem(start_test_worker(name), 1)

      assert length(pids) == 5
      assert Enum.all?(pids, &Process.alive?/1)

      # All should be children of the supervisor
      children = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
      child_pids = for {:undefined, pid, :worker, _} <- children, do: pid

      for pid <- pids do
        assert pid in child_pids
      end

      Enum.each(pids, &cleanup_child/1)
    end

    test "can terminate a child process" do
      name = unique_name()
      {:ok, pid} = start_test_worker(name)

      assert Process.alive?(pid)

      :ok = DynamicSupervisor.terminate_child(Ai.ProviderSupervisor, pid)

      refute Process.alive?(pid)
      assert Process.whereis(name) == nil
    end

    test "which_children returns all active children" do
      name1 = unique_name()
      name2 = unique_name()

      {:ok, pid1} = start_test_worker(name1)
      {:ok, pid2} = start_test_worker(name2)

      children = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
      child_pids = for {:undefined, pid, :worker, _} <- children, do: pid

      assert pid1 in child_pids
      assert pid2 in child_pids

      cleanup_child(pid1)
      cleanup_child(pid2)
    end

    test "count_children returns correct counts" do
      name = unique_name()
      {:ok, pid} = start_test_worker(name)

      counts = DynamicSupervisor.count_children(Ai.ProviderSupervisor)

      assert counts[:active] >= 1
      assert counts[:workers] >= 1
      assert counts[:supervisors] == 0

      cleanup_child(pid)
    end

    test "child process receives correct options" do
      name = unique_name()
      {:ok, pid} = start_test_worker(name, custom_data: :test_value)

      state = GenServer.call(pid, :get_state)
      assert state.opts[:custom_data] == :test_value

      cleanup_child(pid)
    end
  end

  # ============================================================================
  # Dynamic Provider Addition Tests
  # ============================================================================

  describe "dynamic provider addition" do
    test "can add provider services dynamically" do
      name = unique_name()

      child_spec = %{
        id: name,
        start: {TestWorker, :start_link, [[name: name]]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      }

      {:ok, pid} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)

      assert is_pid(pid)
      assert Process.alive?(pid)

      cleanup_child(pid)
    end

    test "adding same provider twice returns already_started" do
      name = unique_name()

      child_spec = %{
        id: name,
        start: {TestWorker, :start_link, [[name: name]]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      }

      {:ok, pid1} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)

      # Trying to start again with same name should fail
      result = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)
      assert {:error, {:already_started, ^pid1}} = result

      cleanup_child(pid1)
    end

    test "can add multiple different providers" do
      providers =
        for i <- 1..3 do
          name = :"provider_#{i}_#{System.unique_integer([:positive])}"

          child_spec = %{
            id: name,
            start: {TestWorker, :start_link, [[name: name]]},
            restart: :temporary,
            shutdown: 5_000,
            type: :worker
          }

          {:ok, pid} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)
          {name, pid}
        end

      assert length(providers) == 3

      for {_name, pid} <- providers do
        assert Process.alive?(pid)
        cleanup_child(pid)
      end
    end

    test "can add provider with different restart strategies" do
      for restart <- [:permanent, :temporary, :transient] do
        name = unique_name()

        child_spec = %{
          id: name,
          start: {TestWorker, :start_link, [[name: name]]},
          restart: restart,
          shutdown: 5_000,
          type: :worker
        }

        {:ok, pid} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)
        assert Process.alive?(pid)
        cleanup_child(pid)
      end
    end
  end

  # ============================================================================
  # Error Isolation Tests
  # ============================================================================

  describe "error isolation between providers" do
    test "crash in one provider does not affect others" do
      name1 = unique_name()
      name2 = unique_name()
      name3 = unique_name()

      {:ok, pid1} = start_test_worker(name1)
      {:ok, pid2} = start_test_worker(name2)
      {:ok, pid3} = start_test_worker(name3)

      # Crash pid2
      Process.exit(pid2, :kill)
      Process.sleep(50)

      # Others should still be alive
      assert Process.alive?(pid1)
      assert Process.alive?(pid3)

      cleanup_child(pid1)
      cleanup_child(pid3)
    end

    test "supervisor survives child crash" do
      sup_pid = Process.whereis(Ai.ProviderSupervisor)
      name = unique_name()

      {:ok, pid} = start_test_worker(name)
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Supervisor should still be the same pid
      assert Process.whereis(Ai.ProviderSupervisor) == sup_pid
      assert Process.alive?(sup_pid)
    end

    test "child crash does not propagate to supervisor" do
      name = unique_name()

      child_spec = %{
        id: name,
        start: {TestWorker, :start_link, [[name: name]]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }

      {:ok, pid} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)

      # Send crash message
      try do
        GenServer.call(pid, :crash)
      catch
        :exit, _ -> :expected
      end

      Process.sleep(50)

      # Supervisor should still be alive
      assert Process.alive?(Process.whereis(Ai.ProviderSupervisor))
    end

    test "multiple simultaneous crashes are isolated" do
      names = for _ <- 1..5, do: unique_name()
      pids = for name <- names, do: elem(start_test_worker(name), 1)

      # Kill all but one
      surviving_pid = List.last(pids)

      pids
      |> Enum.take(4)
      |> Enum.each(&Process.exit(&1, :kill))

      Process.sleep(100)

      # The survivor should still be alive
      assert Process.alive?(surviving_pid)

      # Supervisor should be alive
      assert Process.alive?(Process.whereis(Ai.ProviderSupervisor))

      cleanup_child(surviving_pid)
    end

    test "exception in child init does not crash supervisor" do
      sup_pid = Process.whereis(Ai.ProviderSupervisor)

      child_spec = %{
        id: :crashing_worker,
        start: {CrashingWorker, :start_link, [[]]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }

      # This should fail but not crash the supervisor
      {:error, :intentional_crash} =
        DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)

      assert Process.whereis(Ai.ProviderSupervisor) == sup_pid
    end
  end

  # ============================================================================
  # Supervisor Restart Strategy Tests
  # ============================================================================

  describe "supervisor restart strategies" do
    test "permanent child is restarted after crash" do
      name = unique_name()

      child_spec = %{
        id: name,
        start: {TestWorker, :start_link, [[name: name]]},
        restart: :permanent,
        shutdown: 5_000,
        type: :worker
      }

      {:ok, pid1} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)
      Process.exit(pid1, :kill)
      Process.sleep(100)

      # Should be restarted with a new pid
      pid2 = Process.whereis(name)
      assert pid2 != nil
      assert pid2 != pid1
      assert Process.alive?(pid2)

      cleanup_child(pid2)
    end

    test "temporary child is not restarted after crash" do
      name = unique_name()

      child_spec = %{
        id: name,
        start: {TestWorker, :start_link, [[name: name]]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }

      {:ok, pid} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)
      Process.exit(pid, :kill)
      Process.sleep(100)

      # Should not be restarted
      assert Process.whereis(name) == nil
    end

    test "transient child is restarted only on abnormal exit" do
      name = unique_name()

      child_spec = %{
        id: name,
        start: {TestWorker, :start_link, [[name: name]]},
        restart: :transient,
        shutdown: 5_000,
        type: :worker
      }

      {:ok, pid1} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)

      # Kill with :kill (abnormal exit)
      Process.exit(pid1, :kill)
      Process.sleep(100)

      # Should be restarted
      pid2 = Process.whereis(name)
      assert pid2 != nil
      assert pid2 != pid1

      # Normal exit - stop gracefully
      GenServer.stop(pid2, :normal)
      Process.sleep(100)

      # Should not be restarted after normal exit
      assert Process.whereis(name) == nil
    end

    test "child with shutdown timeout is given time to cleanup" do
      name = unique_name()

      child_spec = %{
        id: name,
        start: {TestWorker, :start_link, [[name: name]]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }

      {:ok, pid} = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)

      # Terminate gracefully - should respect shutdown timeout
      :ok = DynamicSupervisor.terminate_child(Ai.ProviderSupervisor, pid)

      refute Process.alive?(pid)
    end
  end

  # ============================================================================
  # Integration with ProviderRegistry Tests
  # ============================================================================

  describe "integration with ProviderRegistry" do
    test "supervisor and registry are both running" do
      assert Process.whereis(Ai.ProviderSupervisor) != nil
      assert Ai.ProviderRegistry.initialized?()
    end

    test "can start CircuitBreaker under supervisor" do
      provider = :"test_cb_#{System.unique_integer([:positive])}"

      {:ok, pid} = Ai.CircuitBreaker.ensure_started(provider)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Should be a child of ProviderSupervisor
      children = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
      child_pids = for {:undefined, p, :worker, _} <- children, do: p
      assert pid in child_pids
    end

    test "can start RateLimiter under supervisor" do
      provider = :"test_rl_#{System.unique_integer([:positive])}"

      {:ok, pid} = Ai.RateLimiter.ensure_started(provider)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Should be a child of ProviderSupervisor
      children = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
      child_pids = for {:undefined, p, :worker, _} <- children, do: p
      assert pid in child_pids
    end

    test "CircuitBreaker and RateLimiter for same provider coexist" do
      provider = :"test_combined_#{System.unique_integer([:positive])}"

      {:ok, cb_pid} = Ai.CircuitBreaker.ensure_started(provider)
      {:ok, rl_pid} = Ai.RateLimiter.ensure_started(provider)

      assert cb_pid != rl_pid
      assert Process.alive?(cb_pid)
      assert Process.alive?(rl_pid)

      # Both should be children
      children = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
      child_pids = for {:undefined, p, :worker, _} <- children, do: p
      assert cb_pid in child_pids
      assert rl_pid in child_pids
    end

    test "provider services survive registry operations" do
      provider = :"test_survive_#{System.unique_integer([:positive])}"

      {:ok, cb_pid} = Ai.CircuitBreaker.ensure_started(provider)

      # Register and unregister from ProviderRegistry
      Ai.ProviderRegistry.register(provider, TestModule)
      assert Ai.ProviderRegistry.registered?(provider)

      Ai.ProviderRegistry.unregister(provider)
      refute Ai.ProviderRegistry.registered?(provider)

      # CircuitBreaker should still be alive (it's a separate concern)
      assert Process.alive?(cb_pid)
    end
  end

  # ============================================================================
  # Concurrency Tests
  # ============================================================================

  describe "concurrency" do
    test "can start multiple children concurrently" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            name = :"concurrent_#{i}_#{System.unique_integer([:positive])}"
            start_test_worker(name)
          end)
        end

      results = Task.await_many(tasks, 5000)

      pids = for {:ok, pid} <- results, do: pid
      assert length(pids) == 10
      assert Enum.all?(pids, &Process.alive?/1)

      Enum.each(pids, &cleanup_child/1)
    end

    test "concurrent access to supervisor does not cause issues" do
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            name = unique_name()
            {:ok, pid} = start_test_worker(name)
            _ = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
            _ = DynamicSupervisor.count_children(Ai.ProviderSupervisor)
            cleanup_child(pid)
            :ok
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "supervisor handles rapid start/stop cycles" do
      for _ <- 1..10 do
        name = unique_name()
        {:ok, pid} = start_test_worker(name)
        assert Process.alive?(pid)
        cleanup_child(pid)
      end

      # Supervisor should still be healthy
      assert Process.alive?(Process.whereis(Ai.ProviderSupervisor))
    end
  end

  # ============================================================================
  # Edge Cases and Error Handling Tests
  # ============================================================================

  describe "edge cases and error handling" do
    test "terminating non-existent child returns error" do
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      result = DynamicSupervisor.terminate_child(Ai.ProviderSupervisor, fake_pid)
      assert result == {:error, :not_found}
    end

    test "supervisor handles child with bad start function" do
      child_spec = %{
        id: :bad_start,
        start: {NonExistentModule, :start_link, [[]]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }

      result = DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)
      assert {:error, _} = result

      # Supervisor should still be alive
      assert Process.alive?(Process.whereis(Ai.ProviderSupervisor))
    end

    test "supervisor handles empty child spec gracefully" do
      # This should fail validation
      result =
        try do
          DynamicSupervisor.start_child(Ai.ProviderSupervisor, %{})
        rescue
          e -> {:error, e}
        end

      assert {:error, _} = result
      assert Process.alive?(Process.whereis(Ai.ProviderSupervisor))
    end

    test "can query supervisor after many operations" do
      # Perform many operations
      for _ <- 1..50 do
        name = unique_name()
        {:ok, pid} = start_test_worker(name)
        cleanup_child(pid)
      end

      # Supervisor should still respond correctly
      children = DynamicSupervisor.which_children(Ai.ProviderSupervisor)
      assert is_list(children)

      counts = DynamicSupervisor.count_children(Ai.ProviderSupervisor)
      assert is_map(counts)
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp start_test_worker(name, extra_opts \\ []) do
    opts = Keyword.merge([name: name], extra_opts)

    child_spec = %{
      id: name,
      start: {TestWorker, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(Ai.ProviderSupervisor, child_spec)
  end
end
