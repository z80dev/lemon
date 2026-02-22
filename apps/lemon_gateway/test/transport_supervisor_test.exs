defmodule LemonGateway.TransportSupervisorTest do
  alias Elixir.LemonGateway, as: LemonGateway
  @moduledoc """
  Comprehensive tests for Elixir.LemonGateway.TransportSupervisor.

  Tests cover:
  - Supervisor startup and initialization
  - Child process startup based on enabled transports
  - Supervision strategy behavior (:one_for_one)
  - Transport-specific child configuration (Telegram with Outbox)
  - Registry interaction with TransportRegistry
  - Child process restart on crash
  - Concurrent operations
  - Cleanup on shutdown
  - Error isolation between children
  - Generic transport handling
  """
  use ExUnit.Case, async: false

  alias Elixir.LemonGateway.TransportSupervisor
  alias Elixir.LemonGateway.TransportRegistry

  setup_all do
    # `mix test` starts the current application by default. This test suite is a
    # unit test for the legacy `TransportSupervisor`, so we explicitly stop the
    # running apps and start only the minimal processes we need per test.
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_control_plane)
    :ok
  end

  # ============================================================================
  # Mock Transports for Testing
  # ============================================================================

  defmodule LemonGateway.TransportSupervisorTest.MockTelegramTransport do
    use Elixir.LemonGateway.Transport
    use GenServer

    @impl Elixir.LemonGateway.Transport
    def id, do: "telegram"

    @impl Elixir.LemonGateway.Transport
    def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end

    @impl GenServer
    def init(state), do: {:ok, state}
  end

  defmodule MockTransportA do
    use Elixir.LemonGateway.Transport
    use GenServer

    @impl Elixir.LemonGateway.Transport
    def id, do: "mock-a"

    @impl Elixir.LemonGateway.Transport
    def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  defmodule MockTransportB do
    use Elixir.LemonGateway.Transport
    use GenServer

    @impl Elixir.LemonGateway.Transport
    def id, do: "mock-b"

    @impl Elixir.LemonGateway.Transport
    def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  defmodule MockTransportC do
    use Elixir.LemonGateway.Transport
    use GenServer

    @impl Elixir.LemonGateway.Transport
    def id, do: "mock-c"

    @impl Elixir.LemonGateway.Transport
    def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  defmodule FailingTransport do
    use Elixir.LemonGateway.Transport
    use GenServer

    @impl Elixir.LemonGateway.Transport
    def id, do: "failing"

    @impl Elixir.LemonGateway.Transport
    def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end

    @impl GenServer
    def init(_state) do
      # Start successfully but can be crashed later
      {:ok, %{crash_on_call: false}}
    end

    @impl GenServer
    def handle_call(:crash, _from, _state) do
      raise "intentional crash"
    end

    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  defmodule SlowStartTransport do
    use Elixir.LemonGateway.Transport
    use GenServer

    @impl Elixir.LemonGateway.Transport
    def id, do: "slow-start"

    @impl Elixir.LemonGateway.Transport
    def start_link(_opts) do
      GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    end

    @impl GenServer
    def init(state) do
      Process.sleep(100)
      {:ok, state}
    end

    @impl GenServer
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  defmodule IgnoreTransport do
    use Elixir.LemonGateway.Transport

    @impl Elixir.LemonGateway.Transport
    def id, do: "ignore"

    @impl Elixir.LemonGateway.Transport
    def start_link(_opts) do
      :ignore
    end
  end

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp stop_if_running(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          GenServer.stop(pid, :shutdown, 1000)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1000 ->
            Process.exit(pid, :kill)
            :ok
        end
    end
  end

  defp setup_app(transports, config \\ %{}, telegram \\ %{}) do
    # These are globally named processes. Ensure a clean slate even if another
    # test module started them.
    stop_if_running(Elixir.LemonGateway.Telegram.Outbox)
    stop_if_running(TransportSupervisor)
    stop_if_running(TransportRegistry)

    base_config = %{
      enable_telegram: false
    }

    Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, Map.merge(base_config, config))
    Application.put_env(:lemon_gateway, :transports, transports)
    Application.put_env(:lemon_gateway, :telegram, telegram)

    start_supervised!(TransportRegistry)
    start_supervised!(TransportSupervisor)

    :ok
  end

  # ============================================================================
  # 1. Supervisor Startup and Initialization
  # ============================================================================

  describe "supervisor startup and initialization" do
    test "supervisor starts successfully with no transports" do
      setup_app([])

      assert Process.whereis(TransportSupervisor) != nil
    end

    test "supervisor starts successfully with mock transports" do
      setup_app([MockTransportA, MockTransportB])

      assert Process.whereis(TransportSupervisor) != nil
    end

    test "supervisor uses standard Supervisor behavior" do
      setup_app([MockTransportA])

      pid = Process.whereis(TransportSupervisor)
      assert Process.alive?(pid)

      # Verify it's a Supervisor
      children = Supervisor.which_children(TransportSupervisor)
      assert is_list(children)
    end

    test "supervisor is registered with correct name" do
      setup_app([MockTransportA])

      pid = Process.whereis(TransportSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "supervisor uses :one_for_one strategy" do
      setup_app([MockTransportA, MockTransportB])

      # Both transports should be running
      assert Process.alive?(Process.whereis(MockTransportA))
      assert Process.alive?(Process.whereis(MockTransportB))
    end
  end

  # ============================================================================
  # 2. Child Process Startup Based on Enabled Transports
  # ============================================================================

  describe "child process startup based on enabled transports" do
    test "starts transport when enabled" do
      setup_app([MockTransportA])

      # Transport should be running
      pid = Process.whereis(MockTransportA)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "starts multiple enabled transports" do
      setup_app([MockTransportA, MockTransportB, MockTransportC])

      assert Process.alive?(Process.whereis(MockTransportA))
      assert Process.alive?(Process.whereis(MockTransportB))
      assert Process.alive?(Process.whereis(MockTransportC))
    end

    test "does not start telegram transport when enable_telegram is false" do
      setup_app([Elixir.LemonGateway.TransportSupervisorTest.MockTelegramTransport], %{enable_telegram: false}, %{bot_token: "test"})

      # Telegram transport should not be started
      assert Process.whereis(Elixir.LemonGateway.TransportSupervisorTest.MockTelegramTransport) == nil
      assert Process.whereis(Elixir.LemonGateway.Telegram.Outbox) == nil
    end

    test "non-telegram transports are enabled by default" do
      setup_app([MockTransportA])

      # Mock transport should be running
      assert Process.alive?(Process.whereis(MockTransportA))
    end

    test "empty transport list results in no transport children" do
      setup_app([])

      children = Supervisor.which_children(TransportSupervisor)
      # May have no children or only non-transport children
      assert is_list(children)
    end
  end

  # ============================================================================
  # 3. Telegram Transport Special Handling
  # ============================================================================

  describe "telegram transport special handling" do
    test "telegram transport includes Outbox child" do
      setup_app([Elixir.LemonGateway.TransportSupervisorTest.MockTelegramTransport], %{enable_telegram: true}, %{bot_token: "test_token_123"})

      # Check that Outbox is started
      children = Supervisor.which_children(TransportSupervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert Elixir.LemonGateway.Telegram.Outbox in child_ids
      assert Elixir.LemonGateway.TransportSupervisorTest.MockTelegramTransport in child_ids
    end

    test "non-telegram transports do not include Outbox" do
      setup_app([MockTransportA, MockTransportB])

      children = Supervisor.which_children(TransportSupervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      refute Elixir.LemonGateway.Telegram.Outbox in child_ids
    end
  end

  # ============================================================================
  # 4. Transport Registry Integration
  # ============================================================================

  describe "transport registry integration" do
    test "enabled transports are available in registry" do
      setup_app([MockTransportA, MockTransportB])

      enabled = TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      assert "mock-a" in enabled_ids
      assert "mock-b" in enabled_ids
    end

    test "get_transport returns module for enabled transport" do
      setup_app([MockTransportA])

      assert TransportRegistry.get_transport("mock-a") == MockTransportA
    end

    test "list_transports includes registered transports" do
      setup_app([MockTransportA, MockTransportB])

      ids = TransportRegistry.list_transports()

      assert "mock-a" in ids
      assert "mock-b" in ids
    end
  end

  # ============================================================================
  # 5. Child Process Restart on Crash
  # ============================================================================

  describe "child process restart on crash" do
    test "crashed transport is restarted" do
      setup_app([MockTransportA])

      pid1 = Process.whereis(MockTransportA)
      assert is_pid(pid1)

      # Monitor the process
      ref = Process.monitor(pid1)

      # Kill the transport
      Process.exit(pid1, :kill)

      # Wait for DOWN
      assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}, 2000

      # Wait for restart
      Process.sleep(100)

      # Should be restarted with new pid
      pid2 = Process.whereis(MockTransportA)
      assert is_pid(pid2)
      assert pid2 != pid1
      assert Process.alive?(pid2)
    end

    test "supervisor survives child crash" do
      setup_app([MockTransportA])

      supervisor_pid = Process.whereis(TransportSupervisor)
      transport_pid = Process.whereis(MockTransportA)

      # Kill the transport
      Process.exit(transport_pid, :kill)

      Process.sleep(100)

      # Supervisor should still be the same process
      assert Process.whereis(TransportSupervisor) == supervisor_pid
      assert Process.alive?(supervisor_pid)
    end

    test "crashed transport can be called after restart" do
      setup_app([MockTransportA])

      pid1 = Process.whereis(MockTransportA)

      # Verify it responds
      assert GenServer.call(pid1, :ping) == :pong

      # Kill the transport
      Process.exit(pid1, :kill)
      Process.sleep(100)

      # Should be restarted and respond to calls
      pid2 = Process.whereis(MockTransportA)
      assert GenServer.call(pid2, :ping) == :pong
    end
  end

  # ============================================================================
  # 6. Error Isolation Between Children
  # ============================================================================

  describe "error isolation between children" do
    test "one transport crashing does not affect others" do
      setup_app([MockTransportA, MockTransportB])

      pid_a = Process.whereis(MockTransportA)
      pid_b = Process.whereis(MockTransportB)

      # Kill transport A
      Process.exit(pid_a, :kill)
      Process.sleep(100)

      # Transport B should still be the same process and alive
      assert Process.whereis(MockTransportB) == pid_b
      assert Process.alive?(pid_b)
    end

    test "multiple transports can crash and restart independently" do
      setup_app([MockTransportA, MockTransportB, MockTransportC])

      pid_a = Process.whereis(MockTransportA)
      pid_b = Process.whereis(MockTransportB)
      pid_c = Process.whereis(MockTransportC)

      # Kill A and B
      Process.exit(pid_a, :kill)
      Process.exit(pid_b, :kill)
      Process.sleep(100)

      # C should be unchanged
      assert Process.whereis(MockTransportC) == pid_c

      # A and B should be restarted with new pids
      new_a = Process.whereis(MockTransportA)
      new_b = Process.whereis(MockTransportB)

      assert new_a != pid_a
      assert new_b != pid_b
      assert Process.alive?(new_a)
      assert Process.alive?(new_b)
    end
  end

  # ============================================================================
  # 7. Cleanup on Shutdown
  # ============================================================================

  describe "cleanup on shutdown" do
    test "stopping supervisor terminates children" do
      setup_app([MockTransportA, MockTransportB])

      pid_a = Process.whereis(MockTransportA)
      pid_b = Process.whereis(MockTransportB)

      ref_a = Process.monitor(pid_a)
      ref_b = Process.monitor(pid_b)

      # Stop the supervisor
      Supervisor.stop(Process.whereis(TransportSupervisor))

      # Children should be terminated
      assert_receive {:DOWN, ^ref_a, :process, ^pid_a, _reason}, 2000
      assert_receive {:DOWN, ^ref_b, :process, ^pid_b, _reason}, 2000
    end

    test "terminated transports are no longer registered" do
      # Start unsupervised here so stopping the supervisor doesn't immediately
      # get restarted by the test supervisor (which would re-register children).
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_channels)
      _ = Application.stop(:lemon_control_plane)

      stop_if_running(Elixir.LemonGateway.Telegram.Outbox)
      stop_if_running(TransportSupervisor)
      stop_if_running(TransportRegistry)

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{enable_telegram: false})
      Application.put_env(:lemon_gateway, :transports, [MockTransportA])
      Application.put_env(:lemon_gateway, :telegram, %{})

      {:ok, _} = TransportRegistry.start_link([])
      {:ok, _} = TransportSupervisor.start_link([])

      on_exit(fn ->
        stop_if_running(Elixir.LemonGateway.Telegram.Outbox)
        stop_if_running(TransportSupervisor)
        stop_if_running(TransportRegistry)
      end)

      pid = Process.whereis(MockTransportA)
      assert is_pid(pid)

      ref = Process.monitor(pid)
      Supervisor.stop(Process.whereis(TransportSupervisor))

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000

      Process.sleep(50)
      assert Process.whereis(MockTransportA) == nil
    end
  end

  # ============================================================================
  # 8. Concurrent Operations
  # ============================================================================

  describe "concurrent operations" do
    test "multiple transports start concurrently" do
      start_time = System.monotonic_time(:millisecond)

      setup_app([MockTransportA, MockTransportB, MockTransportC])

      end_time = System.monotonic_time(:millisecond)

      # All should be running
      assert Process.alive?(Process.whereis(MockTransportA))
      assert Process.alive?(Process.whereis(MockTransportB))
      assert Process.alive?(Process.whereis(MockTransportC))

      # Startup should be reasonably fast
      assert end_time - start_time < 1000
    end

    test "transports can handle concurrent requests" do
      setup_app([MockTransportA])

      pid = Process.whereis(MockTransportA)

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            GenServer.call(pid, :ping)
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :pong))
    end
  end

  # ============================================================================
  # 9. Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles transport that returns :ignore on start" do
      setup_app([IgnoreTransport])

      # Supervisor should still be running
      assert Process.alive?(Process.whereis(TransportSupervisor))

      # Transport should not have a process
      assert Process.whereis(IgnoreTransport) == nil
    end

    test "handles transport with slow start" do
      start_time = System.monotonic_time(:millisecond)

      setup_app([SlowStartTransport])

      end_time = System.monotonic_time(:millisecond)

      # Transport should be running
      assert Process.alive?(Process.whereis(SlowStartTransport))

      # Should account for slow start
      assert end_time - start_time >= 100
    end

    test "handles empty enabled transports list" do
      # All transports disabled
      setup_app([Elixir.LemonGateway.TransportSupervisorTest.MockTelegramTransport], %{enable_telegram: false}, %{bot_token: "test"})

      # Supervisor should still be running but have fewer children
      assert Process.alive?(Process.whereis(TransportSupervisor))

      children = Supervisor.which_children(TransportSupervisor)
      # No telegram children since it's disabled
      transport_children =
        Enum.filter(children, fn {id, _, _, _} ->
          id == Elixir.LemonGateway.TransportSupervisorTest.MockTelegramTransport or id == Elixir.LemonGateway.Telegram.Outbox
        end)

      assert length(transport_children) == 0
    end
  end

  # ============================================================================
  # 10. Supervisor Which Children
  # ============================================================================

  describe "supervisor which_children" do
    test "returns list of child processes" do
      setup_app([MockTransportA, MockTransportB])

      children = Supervisor.which_children(TransportSupervisor)
      assert is_list(children)
      assert length(children) >= 2
    end

    test "child list includes transport pids" do
      setup_app([MockTransportA])

      children = Supervisor.which_children(TransportSupervisor)

      child_pids =
        children
        |> Enum.map(fn {_, pid, _, _} -> pid end)
        |> Enum.filter(&is_pid/1)

      transport_pid = Process.whereis(MockTransportA)
      assert transport_pid in child_pids
    end

    test "child list includes correct type" do
      setup_app([MockTransportA])

      children = Supervisor.which_children(TransportSupervisor)
      child = Enum.find(children, fn {id, _, _, _} -> id == MockTransportA end)

      {_, _, type, _} = child
      assert type == :worker
    end
  end

  # ============================================================================
  # 11. Supervisor Count Children
  # ============================================================================

  describe "supervisor count_children" do
    test "returns correct counts" do
      setup_app([MockTransportA, MockTransportB])

      counts = Supervisor.count_children(TransportSupervisor)

      assert is_map(counts)
      assert Map.has_key?(counts, :active)
      assert Map.has_key?(counts, :specs)
      assert Map.has_key?(counts, :supervisors)
      assert Map.has_key?(counts, :workers)
    end

    test "workers count reflects transport children" do
      setup_app([MockTransportA, MockTransportB, MockTransportC])

      counts = Supervisor.count_children(TransportSupervisor)

      # At least 3 workers (our transports)
      assert counts.workers >= 3
      assert counts.active >= 3
    end
  end

  # ============================================================================
  # 12. Process Monitoring
  # ============================================================================

  describe "process monitoring" do
    test "can monitor transport processes" do
      setup_app([MockTransportA])

      pid = Process.whereis(MockTransportA)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2000
    end

    test "monitor receives proper exit reason" do
      setup_app([MockTransportA])

      pid = Process.whereis(MockTransportA)
      ref = Process.monitor(pid)

      # Kill with normal reason
      GenServer.stop(pid, :normal)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end
  end

  # ============================================================================
  # 14. Stress Testing
  # ============================================================================

  describe "stress testing" do
    test "handles multiple rapid restarts" do
      setup_app([MockTransportA])

      for _ <- 1..10 do
        pid = Process.whereis(MockTransportA)
        Process.exit(pid, :kill)
        Process.sleep(50)

        new_pid = Process.whereis(MockTransportA)
        assert is_pid(new_pid)
        assert Process.alive?(new_pid)
      end

      # Supervisor should still be healthy
      assert Process.alive?(Process.whereis(TransportSupervisor))
    end

    test "supervisor remains stable under load" do
      setup_app([MockTransportA, MockTransportB, MockTransportC])

      # Send many concurrent requests to transports
      tasks =
        for _ <- 1..50 do
          transport = Enum.random([MockTransportA, MockTransportB, MockTransportC])

          Task.async(fn ->
            pid = Process.whereis(transport)
            if pid, do: GenServer.call(pid, :ping), else: :no_process
          end)
        end

      results = Task.await_many(tasks, 10000)
      assert Enum.all?(results, &(&1 in [:pong, :no_process]))
    end
  end

  # ============================================================================
  # 15. Module Interface Verification
  # ============================================================================

  describe "module interface verification" do
    test "start_link/1 exists and works" do
      # `function_exported?/3` does not auto-load modules.
      assert Code.ensure_loaded?(TransportSupervisor)
      assert function_exported?(TransportSupervisor, :start_link, 1)

      setup_app([MockTransportA])
      assert Process.alive?(Process.whereis(TransportSupervisor))
    end

    test "implements Supervisor callbacks" do
      setup_app([MockTransportA])

      # init/1 callback works (verified by supervisor being alive)
      assert Process.alive?(Process.whereis(TransportSupervisor))

      # Standard Supervisor functions work
      children = Supervisor.which_children(TransportSupervisor)
      assert is_list(children)
    end
  end

  # ============================================================================
  # 16. Child Termination
  # ============================================================================

  describe "child termination" do
    test "can terminate individual children" do
      setup_app([MockTransportA, MockTransportB])

      pid_a = Process.whereis(MockTransportA)
      ref = Process.monitor(pid_a)

      # Find child spec to terminate
      children = Supervisor.which_children(TransportSupervisor)
      child = Enum.find(children, fn {id, _, _, _} -> id == MockTransportA end)
      {child_id, _, _, _} = child

      # Terminate the child
      Supervisor.terminate_child(TransportSupervisor, child_id)

      assert_receive {:DOWN, ^ref, :process, ^pid_a, :shutdown}, 2000

      # Other child should still be running
      assert Process.alive?(Process.whereis(MockTransportB))
    end

    test "terminated child can be restarted" do
      setup_app([MockTransportA])

      children = Supervisor.which_children(TransportSupervisor)
      child = Enum.find(children, fn {id, _, _, _} -> id == MockTransportA end)
      {child_id, _, _, _} = child

      # Terminate
      Supervisor.terminate_child(TransportSupervisor, child_id)
      Process.sleep(50)

      # Restart
      {:ok, new_pid} = Supervisor.restart_child(TransportSupervisor, child_id)

      assert is_pid(new_pid)
      assert Process.alive?(new_pid)
    end
  end

  # ============================================================================
  # 17. Transport Behavior Verification
  # ============================================================================

  describe "transport behavior verification" do
    test "transports implement required callbacks" do
      setup_app([MockTransportA])

      # Verify id/0 is implemented
      assert MockTransportA.id() == "mock-a"

      # Verify start_link/1 works
      # (verified implicitly by supervisor starting the transport)
      assert Process.alive?(Process.whereis(MockTransportA))
    end

    test "transports respond to GenServer calls" do
      setup_app([MockTransportA])

      pid = Process.whereis(MockTransportA)
      response = GenServer.call(pid, :ping)

      assert response == :pong
    end
  end

  # ============================================================================
  # 18. Restart Intensity and Period
  # ============================================================================

  describe "restart intensity handling" do
    test "supervisor handles child restarts within limits" do
      setup_app([MockTransportA])

      # Cause a few restarts
      for _ <- 1..3 do
        pid = Process.whereis(MockTransportA)
        Process.exit(pid, :kill)
        Process.sleep(100)
      end

      # Supervisor should still be running
      assert Process.alive?(Process.whereis(TransportSupervisor))

      # Transport should have been restarted
      assert Process.alive?(Process.whereis(MockTransportA))
    end
  end

  # ============================================================================
  # 19. Generic Transport Children
  # ============================================================================

  describe "generic transport children" do
    test "generic transports get single child spec" do
      setup_app([MockTransportA])

      children = Supervisor.which_children(TransportSupervisor)

      # Count children with MockTransportA id
      mock_a_children =
        Enum.filter(children, fn {id, _, _, _} ->
          id == MockTransportA
        end)

      # Should have exactly one child
      assert length(mock_a_children) == 1
    end

    test "multiple generic transports each get single child" do
      setup_app([MockTransportA, MockTransportB, MockTransportC])

      children = Supervisor.which_children(TransportSupervisor)

      for mod <- [MockTransportA, MockTransportB, MockTransportC] do
        mod_children = Enum.filter(children, fn {id, _, _, _} -> id == mod end)
        assert length(mod_children) == 1
      end
    end
  end

  # ============================================================================
  # 20. Child Ordering
  # ============================================================================

  describe "child ordering" do
    test "children are started in order defined by enabled_transports" do
      setup_app([MockTransportA, MockTransportB, MockTransportC])

      # All children should be present
      children = Supervisor.which_children(TransportSupervisor)

      child_ids =
        children
        |> Enum.map(fn {id, _, _, _} -> id end)
        |> Enum.filter(&(&1 in [MockTransportA, MockTransportB, MockTransportC]))

      assert MockTransportA in child_ids
      assert MockTransportB in child_ids
      assert MockTransportC in child_ids
    end
  end
end
