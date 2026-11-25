defmodule LemonGateway.ApplicationTest do
  alias Elixir.LemonGateway, as: LemonGateway
  use ExUnit.Case, async: false
  import LemonGateway.Test.AppIsolation

  import LemonPlatformTest.Testing.AsyncHelpers,
    only: [assert_eventually: 1, assert_eventually: 2]

  alias Elixir.LemonGateway.ExecutionRequest

  @moduledoc """
  Comprehensive tests for Elixir.LemonGateway.Application startup, supervision tree,
  and configuration loading.
  """

  @gateway_ingress_children [
    Elixir.LemonGateway.TransportRegistry,
    Elixir.LemonGateway.TransportSupervisor,
    # SMS children start only with usable SMS config; see Sms.AvailabilityTest.
    Elixir.LemonGateway.Voice.CallRegistry,
    Elixir.LemonGateway.Voice.DeepgramRegistry,
    Elixir.LemonGateway.Voice.CallSessionSupervisor,
    Elixir.LemonGateway.Voice.DeepgramSupervisor
  ]

  defmodule MockTelegramTransportApp do
    use Elixir.LemonGateway.Transport

    @impl true
    def id, do: "telegram"

    @impl true
    def start_link(_opts), do: :ignore
  end

  defmodule ApplicationValidExecutor do
    @behaviour Elixir.LemonGateway.Executor

    @impl true
    def start_run(%Elixir.LemonGateway.ExecutionRequest{}, _opts, _sink_pid),
      do: {:ok, make_ref(), :application_test_context}

    @impl true
    def cancel(_ctx), do: :ok

    @impl true
    def steer(_ctx, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_ctx, _text), do: {:error, :unsupported}
  end

  # ---------------------------------------------------------------------
  # Test setup helpers
  # ---------------------------------------------------------------------

  defp stop_application do
    _ = Application.stop(:lemon_gateway)
  end

  defp configure_minimal_app do
    Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
      max_concurrent_runs: 2,
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :transports, [])
    Application.put_env(:lemon_gateway, :executor, ApplicationValidExecutor)
  end

  # Blocks until the supervisor has restarted `name` under a new pid and returns it.
  defp await_restart(name, old_pid) do
    assert_eventually(
      fn ->
        pid = Process.whereis(name)
        is_pid(pid) and pid != old_pid
      end,
      message: "expected #{inspect(name)} to be restarted"
    )

    Process.whereis(name)
  end

  # ---------------------------------------------------------------------
  # Application Startup Sequence Tests
  # ---------------------------------------------------------------------

  setup do
    isolate_gateway([LemonGateway.Config, :executor, :transports])
  end

  describe "Application startup sequence" do
    setup do
      configure_minimal_app()
      :ok
    end

    test "application starts successfully" do
      assert {:ok, _pid} = Application.ensure_all_started(:lemon_gateway)

      assert Application.started_applications()
             |> Enum.any?(fn {app, _, _} -> app == :lemon_gateway end)
    end

    test "application can be started and stopped multiple times" do
      for _ <- 1..3 do
        assert {:ok, _pid} = Application.ensure_all_started(:lemon_gateway)
        assert :ok = Application.stop(:lemon_gateway)
      end
    end

    test "main supervisor is registered under Elixir.LemonGateway.Supervisor" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      supervisor_pid = Process.whereis(Elixir.LemonGateway.Supervisor)
      assert is_pid(supervisor_pid)
      assert Process.alive?(supervisor_pid)
    end
  end

  # ---------------------------------------------------------------------
  # Supervision Tree Structure Tests
  # ---------------------------------------------------------------------

  describe "supervision tree structure" do
    setup do
      configure_minimal_app()
      :ok
    end

    test "supervision tree has no EngineRegistry child" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(Elixir.LemonGateway.Supervisor)
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      refute Elixir.LemonGateway.EngineRegistry in child_ids
    end

    test "execution registry dependencies form a bounded restart subtree and voice tasks are capped" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert {:ok, %{start: {Supervisor, :start_link, [children, opts]}}} =
               :supervisor.get_childspec(
                 LemonGateway.Supervisor,
                 LemonGateway.ExecutionSupervisor
               )

      assert opts[:strategy] == :rest_for_one
      assert opts[:max_restarts] == 10
      assert opts[:max_seconds] == 5

      assert Enum.map(children, &Supervisor.child_spec(&1, []).id) == [
               LemonGateway.RunRegistry,
               LemonGateway.Slots,
               LemonGateway.RunSupervisor
             ]

      assert {:ok, %{start: {Task.Supervisor, :start_link, [task_opts]}}} =
               :supervisor.get_childspec(LemonGateway.Supervisor, LemonGateway.TaskSupervisor)

      assert task_opts[:max_children] == 1024
    end

    test "all child processes are running" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(Elixir.LemonGateway.Supervisor)

      for {id, pid, _type, _modules} <- children do
        if is_pid(pid) do
          assert Process.alive?(pid), "Child #{inspect(id)} should be alive"
        else
          # Only the optional webhook server may return :ignore when disabled.
          assert {id, pid} == {Elixir.LemonGateway.Sms.WebhookServer, :undefined},
                 "Child #{inspect(id)} should have a pid (got: #{inspect(pid)})"
        end
      end
    end

    test "ingress children are not started by default" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(Elixir.LemonGateway.Supervisor)
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      for child <- @gateway_ingress_children do
        refute child in child_ids
      end
    end

    test "ingress children start when explicitly enabled" do
      config = Application.fetch_env!(:lemon_gateway, Elixir.LemonGateway.Config)

      Application.put_env(
        :lemon_gateway,
        Elixir.LemonGateway.Config,
        Map.put(config, :ingress, %{enabled: true})
      )

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(Elixir.LemonGateway.Supervisor)
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      assert Elixir.LemonGateway.IngressSupervisor in child_ids

      children = Supervisor.which_children(Elixir.LemonGateway.IngressSupervisor)
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      for child <- @gateway_ingress_children do
        assert child in child_ids
      end
    end
  end

  # ---------------------------------------------------------------------
  # Child Process Initialization Order Tests
  # ---------------------------------------------------------------------

  describe "child process initialization order" do
    setup do
      configure_minimal_app()
      :ok
    end

    test "configured executor is ready after startup" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert Elixir.LemonGateway.Executor.validate_configured() == :ok
    end

    test "Store is initialized after Config" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert is_pid(Process.whereis(LemonCore.Store))

      # Store should be functional
      scope = {:test, 12_345}
      LemonCore.ChatStateStore.put(scope, %{test: true})
      assert_eventually(fn -> match?(%{test: true}, LemonCore.ChatStateStore.get(scope)) end)
    end

    test "RunRegistry is available for run-owned session registration" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      assert is_pid(Process.whereis(LemonGateway.RunRegistry))
      assert Registry.lookup(LemonGateway.RunRegistry, {:session, :nonexistent}) == []
    end
  end

  # ---------------------------------------------------------------------
  # Configuration Loading on Startup Tests
  # ---------------------------------------------------------------------

  describe "configuration loading on startup" do
    test "loads configuration from Application env" do
      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 10,
        enable_telegram: false
      })

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert {:ok, %{max: 10}} = LemonGateway.Slots.stats()
    end

    test "gateway settings use defaults and configured overrides" do
      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{})
      Application.put_env(:lemon_gateway, :transports, [])
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert {:ok, %{max: 2}} = LemonGateway.Slots.stats()

      stop_application()

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 7,
        enable_telegram: true
      })

      Application.put_env(:lemon_gateway, :transports, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert {:ok, %{max: 7}} = LemonGateway.Slots.stats()
      assert LemonCore.GatewayConfig.get(:enable_telegram) == true
    end
  end

  # ---------------------------------------------------------------------
  # Environment-Based Configuration Tests
  # ---------------------------------------------------------------------

  describe "environment-based configuration" do
    test "enable_telegram: false disables telegram transport in TransportRegistry" do
      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 1,
        ingress: %{enabled: true},
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :transports, [__MODULE__.MockTelegramTransportApp])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      enabled = Elixir.LemonGateway.TransportRegistry.enabled_transports()
      enabled_ids = Enum.map(enabled, fn {id, _mod} -> id end)

      refute "telegram" in enabled_ids
    end
  end

  # ---------------------------------------------------------------------
  # Graceful Shutdown Tests
  # ---------------------------------------------------------------------

  describe "graceful shutdown" do
    setup do
      configure_minimal_app()
      :ok
    end

    test "application stops cleanly" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Verify running
      assert is_pid(Process.whereis(Elixir.LemonGateway.Supervisor))

      # Stop application
      assert :ok = Application.stop(:lemon_gateway)

      # Verify stopped
      assert Process.whereis(Elixir.LemonGateway.Supervisor) == nil
    end

    test "all child processes are terminated on shutdown" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Collect all child pids
      children = Supervisor.which_children(Elixir.LemonGateway.Supervisor)

      child_pids =
        children
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
        |> Enum.filter(&is_pid/1)

      # All should be alive
      assert Enum.all?(child_pids, &Process.alive?/1)

      # Stop application
      :ok = Application.stop(:lemon_gateway)

      # All should be dead
      assert Enum.all?(child_pids, fn pid -> not Process.alive?(pid) end)
    end

    test "registered process names are freed after shutdown" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Verify processes are registered
      assert is_pid(Process.whereis(Elixir.LemonGateway.Slots))

      :ok = Application.stop(:lemon_gateway)

      # Names should be freed
      assert Process.whereis(Elixir.LemonGateway.Slots) == nil
    end

    test "application can be restarted after shutdown" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      :ok = Application.stop(:lemon_gateway)

      # Restart
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Verify running
      assert is_pid(Process.whereis(Elixir.LemonGateway.Supervisor))
    end

    test "RunSupervisor starts without children after clean shutdown" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      :ok = Application.stop(:lemon_gateway)
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      assert DynamicSupervisor.which_children(LemonGateway.RunSupervisor) == []
    end
  end

  # ---------------------------------------------------------------------
  # Error Handling During Startup Tests
  # ---------------------------------------------------------------------

  describe "error handling during startup" do
    setup do
      Application.put_env(:lemon_gateway, :executor, ApplicationValidExecutor)
      :ok
    end

    test "startup rejects a configured executor that cannot be loaded" do
      configure_minimal_app()
      executor = LemonGateway.ApplicationTest.UnloadableExecutor
      Application.put_env(:lemon_gateway, :executor, executor)

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
      refute Process.whereis(Elixir.LemonGateway.Supervisor)
    end
  end

  # ---------------------------------------------------------------------
  # Required Children Verification Tests
  # ---------------------------------------------------------------------

  describe "required children verification" do
    setup do
      configure_minimal_app()
      :ok
    end

    test "Slots publishes counters without a claim server" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      assert is_pid(Process.whereis(LemonGateway.Slots))
      assert {:ok, %{max: 2, in_flight: 0, waitq: 0}} = LemonGateway.Slots.stats()
    end

    test "Store process is registered and responding" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonCore.Store)
      assert is_pid(pid)

      # Should respond to calls
      result = LemonCore.ChatStateStore.get({:test, 999})
      assert result == nil
    end

    test "TransportSupervisor is not registered by default" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert Process.whereis(Elixir.LemonGateway.TransportSupervisor) == nil
    end

    test "TransportSupervisor is registered when ingress is enabled" do
      config = Application.fetch_env!(:lemon_gateway, Elixir.LemonGateway.Config)

      Application.put_env(
        :lemon_gateway,
        Elixir.LemonGateway.Config,
        Map.put(config, :ingress, %{enabled: true})
      )

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(Elixir.LemonGateway.TransportSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------
  # Integration Tests
  # ---------------------------------------------------------------------

  describe "integration - full system functionality" do
    setup do
      configure_minimal_app()
      :ok
    end

    test "can submit an execution request after startup" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      session_key = "test:1"

      request = %ExecutionRequest{
        run_id: LemonCore.Id.run_id(),
        session_key: session_key,
        prompt: "test message",
        resume: nil,
        conversation_key: {:session, session_key},
        meta: %{notify_pid: self(), user_msg_id: 1}
      }

      # Submit should succeed
      assert :ok = LemonGateway.Runtime.submit_execution(ExecutionRequest.to_command(request))
    end

    test "Store persists data across operations" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = {:integration_test, System.unique_integer()}

      # Write
      LemonCore.ChatStateStore.put(scope, %{key: "value"})
      assert_eventually(fn -> match?(%{key: "value"}, LemonCore.ChatStateStore.get(scope)) end)

      # Delete
      LemonCore.ChatStateStore.delete(scope)
      assert_eventually(fn -> LemonCore.ChatStateStore.get(scope) == nil end)

      # Verify deleted
      assert LemonCore.ChatStateStore.get(scope) == nil
    end

    test "engine session claims reject a second owner immediately" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      key = {:session, make_ref()}
      assert :ok = LemonGateway.EngineSessionClaim.claim(key)
      task = Task.async(fn -> LemonGateway.EngineSessionClaim.claim(key) end)
      assert Task.await(task) == {:error, :session_in_use}
      assert :ok = LemonGateway.EngineSessionClaim.release(key)
    end
  end

  # ---------------------------------------------------------------------
  # Supervisor Restart Tests
  # ---------------------------------------------------------------------

  describe "supervisor child restart behavior" do
    setup do
      configure_minimal_app()
      :ok
    end

    test "Slots process is restarted if it crashes" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      original_pid = Process.whereis(Elixir.LemonGateway.Slots)
      assert is_pid(original_pid)

      # Kill the process
      Process.exit(original_pid, :kill)

      new_pid = await_restart(Elixir.LemonGateway.Slots, original_pid)
      assert is_pid(new_pid)
      assert new_pid != original_pid
    end

    test "Store process is restarted if it crashes" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      original_pid = Process.whereis(LemonCore.Store)
      assert is_pid(original_pid)

      # Kill the process
      Process.exit(original_pid, :kill)

      new_pid = await_restart(LemonCore.Store, original_pid)
      assert is_pid(new_pid)
      assert new_pid != original_pid

      # Should still be functional
      result = LemonCore.ChatStateStore.get({:test, 1})
      assert result == nil
    end

    test "session ownership registry is supervised" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      children = Supervisor.which_children(LemonGateway.ExecutionSupervisor)

      assert Enum.any?(children, fn {id, pid, _, _} ->
               id == LemonGateway.RunRegistry and is_pid(pid)
             end)
    end
  end
end
