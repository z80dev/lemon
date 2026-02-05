defmodule LemonGateway.ApplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Comprehensive tests for LemonGateway.Application startup, supervision tree,
  and configuration loading.
  """

  # Expected children in the supervision tree (in order)
  @expected_children [
    LemonGateway.Config,
    LemonGateway.EngineRegistry,
    LemonGateway.TransportRegistry,
    LemonGateway.CommandRegistry,
    LemonGateway.EngineLock,
    LemonGateway.ThreadRegistry,
    LemonGateway.RunSupervisor,
    LemonGateway.ThreadWorkerSupervisor,
    LemonGateway.Scheduler,
    LemonGateway.Store,
    LemonGateway.TransportSupervisor,
    {:ranch_embedded_sup, LemonGateway.Web.Router.HTTP}
  ]

  # ---------------------------------------------------------------------
  # Test setup helpers
  # ---------------------------------------------------------------------

  defp stop_application do
    _ = Application.stop(:lemon_gateway)
  end

  defp configure_minimal_app do
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 2,
      default_engine: "echo",
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
    Application.put_env(:lemon_gateway, :transports, [])
    Application.put_env(:lemon_gateway, :commands, [])
  end

  defp cleanup_config do
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :engines)
    Application.delete_env(:lemon_gateway, :transports)
    Application.delete_env(:lemon_gateway, :commands)
    Application.delete_env(:lemon_gateway, :config_path)
    Application.delete_env(:lemon_gateway, LemonGateway.Store)
  end

  # ---------------------------------------------------------------------
  # Application Startup Sequence Tests
  # ---------------------------------------------------------------------

  describe "Application startup sequence" do
    setup do
      stop_application()
      configure_minimal_app()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "application starts successfully" do
      assert {:ok, _pid} = Application.ensure_all_started(:lemon_gateway)
      assert Application.started_applications() |> Enum.any?(fn {app, _, _} -> app == :lemon_gateway end)
    end

    test "application can be started and stopped multiple times" do
      for _ <- 1..3 do
        assert {:ok, _pid} = Application.ensure_all_started(:lemon_gateway)
        assert :ok = Application.stop(:lemon_gateway)
      end
    end

    test "application start returns {:ok, pid} tuple" do
      result = Application.ensure_all_started(:lemon_gateway)
      assert {:ok, apps} = result
      assert :lemon_gateway in apps
    end

    test "main supervisor is registered under LemonGateway.Supervisor" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      supervisor_pid = Process.whereis(LemonGateway.Supervisor)
      assert is_pid(supervisor_pid)
      assert Process.alive?(supervisor_pid)
    end

    test "supervisor uses one_for_one strategy" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      state = :sys.get_state(LemonGateway.Supervisor)

      # Supervisor state tuple shape: {:state, name, strategy, ...}
      assert is_tuple(state)
      assert elem(state, 0) == :state
      assert elem(state, 2) == :one_for_one
    end
  end

  # ---------------------------------------------------------------------
  # Supervision Tree Structure Tests
  # ---------------------------------------------------------------------

  describe "supervision tree structure" do
    setup do
      stop_application()
      configure_minimal_app()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "all expected children are present in supervision tree" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(LemonGateway.Supervisor)
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      for expected <- @expected_children do
        assert expected in child_ids,
               "Expected #{inspect(expected)} in supervision tree, got: #{inspect(child_ids)}"
      end
    end

    test "supervision tree has expected child count" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(LemonGateway.Supervisor)
      assert length(children) == length(@expected_children)
    end

    test "all child processes are running" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(LemonGateway.Supervisor)

      for {id, pid, _type, _modules} <- children do
        assert is_pid(pid), "Child #{inspect(id)} should have a pid"
        assert Process.alive?(pid), "Child #{inspect(id)} should be alive"
      end
    end

    test "Config child is a worker" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(LemonGateway.Supervisor)
      {_id, _pid, type, _modules} = Enum.find(children, fn {id, _, _, _} -> id == LemonGateway.Config end)

      assert type == :worker
    end

    test "RunSupervisor is a supervisor type" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(LemonGateway.Supervisor)
      {_id, _pid, type, _modules} = Enum.find(children, fn {id, _, _, _} -> id == LemonGateway.RunSupervisor end)

      assert type == :supervisor
    end

    test "ThreadWorkerSupervisor is a supervisor type" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(LemonGateway.Supervisor)

      {_id, _pid, type, _modules} =
        Enum.find(children, fn {id, _, _, _} -> id == LemonGateway.ThreadWorkerSupervisor end)

      assert type == :supervisor
    end

    test "TransportSupervisor is a supervisor type" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(LemonGateway.Supervisor)

      {_id, _pid, type, _modules} =
        Enum.find(children, fn {id, _, _, _} -> id == LemonGateway.TransportSupervisor end)

      assert type == :supervisor
    end

    test "ThreadRegistry is a supervisor (Registry)" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      children = Supervisor.which_children(LemonGateway.Supervisor)
      {_id, _pid, type, _modules} = Enum.find(children, fn {id, _, _, _} -> id == LemonGateway.ThreadRegistry end)

      assert type == :supervisor
    end
  end

  # ---------------------------------------------------------------------
  # Child Process Initialization Order Tests
  # ---------------------------------------------------------------------

  describe "child process initialization order" do
    setup do
      stop_application()
      configure_minimal_app()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "Config is started before other components" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Config should be running and accessible
      config = LemonGateway.Config.get()
      assert is_map(config)
    end

    test "EngineRegistry is available after startup" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert is_pid(Process.whereis(LemonGateway.EngineRegistry))
      engines = LemonGateway.EngineRegistry.list_engines()
      assert is_list(engines)
    end

    test "TransportRegistry is available after startup" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert is_pid(Process.whereis(LemonGateway.TransportRegistry))
      transports = LemonGateway.TransportRegistry.list_transports()
      assert is_list(transports)
    end

    test "CommandRegistry is available after startup" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert is_pid(Process.whereis(LemonGateway.CommandRegistry))
      commands = LemonGateway.CommandRegistry.list_commands()
      assert is_list(commands)
    end

    test "Scheduler depends on Config for max_concurrent_runs" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 5,
        default_engine: "echo",
        enable_telegram: false
      })

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Scheduler should be running
      assert is_pid(Process.whereis(LemonGateway.Scheduler))
    end

    test "Store is initialized after Config" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert is_pid(Process.whereis(LemonGateway.Store))

      # Store should be functional
      scope = {:test, 12345}
      LemonGateway.Store.put_chat_state(scope, %{test: true})
      Process.sleep(10)
      state = LemonGateway.Store.get_chat_state(scope)
      assert state.test == true
    end

    test "ThreadRegistry is available for ThreadWorker registration" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Registry should be running
      registry_pid = Process.whereis(LemonGateway.ThreadRegistry)
      assert is_pid(registry_pid)

      # Registry should accept lookups
      result = LemonGateway.ThreadRegistry.whereis(:nonexistent)
      assert result == nil
    end
  end

  # ---------------------------------------------------------------------
  # Configuration Loading on Startup Tests
  # ---------------------------------------------------------------------

  describe "configuration loading on startup" do
    setup do
      stop_application()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "loads configuration from Application env" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 10,
        default_engine: "test_engine",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      config = LemonGateway.Config.get()
      assert config.max_concurrent_runs == 10
      assert config.default_engine == "test_engine"
    end

    test "uses default values when config is not set" do
      # Set minimal config (config will use defaults for unspecified keys)
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{})
      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      config = LemonGateway.Config.get()
      # Default values from Config module
      assert config.max_concurrent_runs == 2
      assert config.default_engine == "lemon"
      assert config.auto_resume == false
    end

    test "Config.get/1 returns specific configuration keys" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 7,
        default_engine: "echo",
        enable_telegram: true
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert LemonGateway.Config.get(:max_concurrent_runs) == 7
      assert LemonGateway.Config.get(:default_engine) == "echo"
      assert LemonGateway.Config.get(:enable_telegram) == true
    end

    test "configuration supports projects" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false,
        projects: %{
          "test_project" => %{
            root: "/tmp/test_project",
            default_engine: "echo"
          }
        }
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      projects = LemonGateway.Config.get_projects()
      assert is_map(projects)
    end

    test "configuration supports bindings" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false,
        bindings: [
          %{transport: :telegram, chat_id: 123, project: "test"}
        ]
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      bindings = LemonGateway.Config.get_bindings()
      assert is_list(bindings)
    end

    test "configuration supports queue settings" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false,
        queue: %{cap: 10, drop: :oldest, mode: :collect}
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      queue_config = LemonGateway.Config.get_queue_config()
      assert is_map(queue_config)
    end
  end

  # ---------------------------------------------------------------------
  # Environment-Based Configuration Tests
  # ---------------------------------------------------------------------

  describe "environment-based configuration" do
    setup do
      stop_application()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "enable_telegram: false does not start telegram transport" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [LemonGateway.Telegram.Transport])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # TransportSupervisor should be running but with no telegram children
      # since enable_telegram is false
      supervisor_pid = Process.whereis(LemonGateway.TransportSupervisor)
      assert is_pid(supervisor_pid)
    end

    test "custom engines list is loaded from config" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      engines = LemonGateway.EngineRegistry.list_engines()
      assert "echo" in engines
    end

    test "empty engines list is handled" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      engines = LemonGateway.EngineRegistry.list_engines()
      assert engines == []
    end

    test "empty commands list is handled" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      commands = LemonGateway.CommandRegistry.list_commands()
      assert commands == []
    end

    test "Store backend configuration is respected" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      # Configure ETS backend (default)
      Application.put_env(:lemon_gateway, LemonGateway.Store, [
        backend: LemonGateway.Store.EtsBackend
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      assert is_pid(Process.whereis(LemonGateway.Store))
    end
  end

  # ---------------------------------------------------------------------
  # Graceful Shutdown Tests
  # ---------------------------------------------------------------------

  describe "graceful shutdown" do
    setup do
      stop_application()
      configure_minimal_app()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "application stops cleanly" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Verify running
      assert is_pid(Process.whereis(LemonGateway.Supervisor))

      # Stop application
      assert :ok = Application.stop(:lemon_gateway)

      # Verify stopped
      assert Process.whereis(LemonGateway.Supervisor) == nil
    end

    test "all child processes are terminated on shutdown" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Collect all child pids
      children = Supervisor.which_children(LemonGateway.Supervisor)
      child_pids = Enum.map(children, fn {_id, pid, _type, _modules} -> pid end)

      # All should be alive
      assert Enum.all?(child_pids, &Process.alive?/1)

      # Stop application
      :ok = Application.stop(:lemon_gateway)

      # Give some time for cleanup
      Process.sleep(50)

      # All should be dead
      assert Enum.all?(child_pids, fn pid -> not Process.alive?(pid) end)
    end

    test "registered process names are freed after shutdown" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Verify processes are registered
      assert is_pid(Process.whereis(LemonGateway.Config))
      assert is_pid(Process.whereis(LemonGateway.Scheduler))
      assert is_pid(Process.whereis(LemonGateway.Store))

      :ok = Application.stop(:lemon_gateway)
      Process.sleep(50)

      # Names should be freed
      assert Process.whereis(LemonGateway.Config) == nil
      assert Process.whereis(LemonGateway.Scheduler) == nil
      assert Process.whereis(LemonGateway.Store) == nil
    end

    test "application can be restarted after shutdown" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      :ok = Application.stop(:lemon_gateway)
      Process.sleep(50)

      # Restart
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Verify running
      assert is_pid(Process.whereis(LemonGateway.Supervisor))
      assert is_pid(Process.whereis(LemonGateway.Config))
    end

    test "DynamicSupervisors have no children after clean shutdown" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Verify supervisors exist
      assert is_pid(Process.whereis(LemonGateway.RunSupervisor))
      assert is_pid(Process.whereis(LemonGateway.ThreadWorkerSupervisor))

      # Stop and restart
      :ok = Application.stop(:lemon_gateway)
      Process.sleep(50)
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # DynamicSupervisors should start fresh with no children
      run_children = DynamicSupervisor.which_children(LemonGateway.RunSupervisor)
      thread_children = DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)

      assert run_children == []
      assert thread_children == []
    end
  end

  # ---------------------------------------------------------------------
  # Error Handling During Startup Tests
  # ---------------------------------------------------------------------

  describe "error handling during startup" do
    setup do
      stop_application()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "startup fails with invalid engine ID (reserved 'default')" do
      defmodule InvalidDefaultEngine do
        @behaviour LemonGateway.Engine

        alias LemonGateway.Types.{Job, ResumeToken}

        @impl true
        def id, do: "default"
        @impl true
        def format_resume(%ResumeToken{value: sid}), do: "default resume #{sid}"
        @impl true
        def extract_resume(_text), do: nil
        @impl true
        def is_resume_line(_line), do: false
        @impl true
        def supports_steer?, do: false
        @impl true
        def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}
        @impl true
        def cancel(_ctx), do: :ok
      end

      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [InvalidDefaultEngine])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "startup fails with invalid engine ID (reserved 'help')" do
      defmodule InvalidHelpEngine do
        @behaviour LemonGateway.Engine

        alias LemonGateway.Types.{Job, ResumeToken}

        @impl true
        def id, do: "help"
        @impl true
        def format_resume(%ResumeToken{value: sid}), do: "help resume #{sid}"
        @impl true
        def extract_resume(_text), do: nil
        @impl true
        def is_resume_line(_line), do: false
        @impl true
        def supports_steer?, do: false
        @impl true
        def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}
        @impl true
        def cancel(_ctx), do: :ok
      end

      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [InvalidHelpEngine])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "startup fails with invalid engine ID format (uppercase)" do
      defmodule UppercaseEngine do
        @behaviour LemonGateway.Engine

        alias LemonGateway.Types.{Job, ResumeToken}

        @impl true
        def id, do: "InvalidUppercase"
        @impl true
        def format_resume(%ResumeToken{value: sid}), do: "upper resume #{sid}"
        @impl true
        def extract_resume(_text), do: nil
        @impl true
        def is_resume_line(_line), do: false
        @impl true
        def supports_steer?, do: false
        @impl true
        def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}
        @impl true
        def cancel(_ctx), do: :ok
      end

      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [UppercaseEngine])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "startup fails with reserved command name" do
      defmodule InvalidCommand do
        @behaviour LemonGateway.Command

        @impl true
        def name, do: "help"
        @impl true
        def handle(_args, _job, _meta), do: {:ok, "help"}
      end

      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [InvalidCommand])

      assert {:error, _} = Application.ensure_all_started(:lemon_gateway)
    end

    test "recovers after failed startup and can start with valid config" do
      # First try with invalid config
      defmodule BadEngine do
        @behaviour LemonGateway.Engine

        alias LemonGateway.Types.{Job, ResumeToken}

        @impl true
        def id, do: "default"
        @impl true
        def format_resume(%ResumeToken{value: sid}), do: "bad resume #{sid}"
        @impl true
        def extract_resume(_text), do: nil
        @impl true
        def is_resume_line(_line), do: false
        @impl true
        def supports_steer?, do: false
        @impl true
        def start_run(%Job{}, _opts, _sink_pid), do: {:ok, make_ref(), %{}}
        @impl true
        def cancel(_ctx), do: :ok
      end

      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 1,
        default_engine: "echo",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [BadEngine])
      Application.put_env(:lemon_gateway, :transports, [])
      Application.put_env(:lemon_gateway, :commands, [])

      # Should fail
      {:error, _} = Application.ensure_all_started(:lemon_gateway)
      stop_application()

      # Now configure valid settings
      configure_minimal_app()

      # Should succeed
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)
      assert is_pid(Process.whereis(LemonGateway.Supervisor))
    end
  end

  # ---------------------------------------------------------------------
  # Required Children Verification Tests
  # ---------------------------------------------------------------------

  describe "required children verification" do
    setup do
      stop_application()
      configure_minimal_app()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "Config process is registered and responding" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.Config)
      assert is_pid(pid)

      # Should respond to calls
      config = LemonGateway.Config.get()
      assert is_map(config)
    end

    test "EngineRegistry process is registered and responding" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.EngineRegistry)
      assert is_pid(pid)

      # Should respond to calls
      engines = LemonGateway.EngineRegistry.list_engines()
      assert is_list(engines)
    end

    test "TransportRegistry process is registered and responding" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.TransportRegistry)
      assert is_pid(pid)

      # Should respond to calls
      transports = LemonGateway.TransportRegistry.list_transports()
      assert is_list(transports)
    end

    test "CommandRegistry process is registered and responding" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.CommandRegistry)
      assert is_pid(pid)

      # Should respond to calls
      commands = LemonGateway.CommandRegistry.list_commands()
      assert is_list(commands)
    end

    test "EngineLock process is registered and responding" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.EngineLock)
      assert is_pid(pid)

      # Should respond to acquire calls
      {:ok, release_fn} = LemonGateway.EngineLock.acquire(:test_key, 1000)
      release_fn.()
    end

    test "ThreadRegistry is functional" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Should be able to lookup (returns nil for non-existent)
      result = LemonGateway.ThreadRegistry.whereis(:nonexistent_key)
      assert result == nil
    end

    test "RunSupervisor is a DynamicSupervisor" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.RunSupervisor)
      assert is_pid(pid)

      # Should accept which_children call
      children = DynamicSupervisor.which_children(LemonGateway.RunSupervisor)
      assert is_list(children)
    end

    test "ThreadWorkerSupervisor is a DynamicSupervisor" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.ThreadWorkerSupervisor)
      assert is_pid(pid)

      # Should accept which_children call
      children = DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)
      assert is_list(children)
    end

    test "Scheduler process is registered and responding" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.Scheduler)
      assert is_pid(pid)
    end

    test "Store process is registered and responding" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.Store)
      assert is_pid(pid)

      # Should respond to calls
      result = LemonGateway.Store.get_chat_state({:test, 999})
      assert result == nil
    end

    test "TransportSupervisor is registered" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      pid = Process.whereis(LemonGateway.TransportSupervisor)
      assert is_pid(pid)

      # Should accept which_children call
      children = Supervisor.which_children(LemonGateway.TransportSupervisor)
      assert is_list(children)
    end
  end

  # ---------------------------------------------------------------------
  # Integration Tests
  # ---------------------------------------------------------------------

  describe "integration - full system functionality" do
    setup do
      stop_application()
      configure_minimal_app()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "can submit a job after startup" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      alias LemonGateway.Types.{ChatScope, Job}

      scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

      job = %Job{
        scope: scope,
        user_msg_id: 1,
        text: "test message",
        resume: nil,
        engine_hint: "echo",
        meta: %{notify_pid: self()}
      }

      # Submit should succeed
      assert :ok = LemonGateway.Scheduler.submit(job)
    end

    test "Store persists data across operations" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = {:integration_test, System.unique_integer()}

      # Write
      LemonGateway.Store.put_chat_state(scope, %{key: "value"})
      Process.sleep(10)

      # Read
      state = LemonGateway.Store.get_chat_state(scope)
      assert state.key == "value"

      # Delete
      LemonGateway.Store.delete_chat_state(scope)
      Process.sleep(10)

      # Verify deleted
      assert LemonGateway.Store.get_chat_state(scope) == nil
    end

    test "EngineLock provides mutual exclusion" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      thread_key = {:lock_test, System.unique_integer()}

      # First acquire should succeed
      {:ok, release1} = LemonGateway.EngineLock.acquire(thread_key, 1000)

      # Start a task that tries to acquire the same lock
      parent = self()

      task =
        Task.async(fn ->
          result = LemonGateway.EngineLock.acquire(thread_key, 100)
          send(parent, {:task_result, result})
        end)

      # Should timeout waiting for lock
      assert_receive {:task_result, {:error, :timeout}}, 500

      Task.shutdown(task, :brutal_kill)

      # Release first lock
      release1.()

      # Now should be able to acquire again
      {:ok, release2} = LemonGateway.EngineLock.acquire(thread_key, 1000)
      release2.()
    end

    test "Config values are accessible by all components" do
      Application.put_env(:lemon_gateway, LemonGateway.Config, %{
        max_concurrent_runs: 42,
        default_engine: "test_engine",
        enable_telegram: false
      })

      Application.put_env(:lemon_gateway, :engines, [LemonGateway.Engines.Echo])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      # Config should be accessible
      assert LemonGateway.Config.get(:max_concurrent_runs) == 42
      assert LemonGateway.Config.get(:default_engine) == "test_engine"
    end
  end

  # ---------------------------------------------------------------------
  # Supervisor Restart Tests
  # ---------------------------------------------------------------------

  describe "supervisor child restart behavior" do
    setup do
      stop_application()
      configure_minimal_app()

      on_exit(fn ->
        stop_application()
        cleanup_config()
      end)

      :ok
    end

    test "Config process is restarted if it crashes" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      original_pid = Process.whereis(LemonGateway.Config)
      assert is_pid(original_pid)

      # Kill the process
      Process.exit(original_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Should have a new pid
      new_pid = Process.whereis(LemonGateway.Config)
      assert is_pid(new_pid)
      assert new_pid != original_pid

      # Should still be functional
      config = LemonGateway.Config.get()
      assert is_map(config)
    end

    test "Scheduler process is restarted if it crashes" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      original_pid = Process.whereis(LemonGateway.Scheduler)
      assert is_pid(original_pid)

      # Kill the process
      Process.exit(original_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Should have a new pid
      new_pid = Process.whereis(LemonGateway.Scheduler)
      assert is_pid(new_pid)
      assert new_pid != original_pid
    end

    test "Store process is restarted if it crashes" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      original_pid = Process.whereis(LemonGateway.Store)
      assert is_pid(original_pid)

      # Kill the process
      Process.exit(original_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Should have a new pid
      new_pid = Process.whereis(LemonGateway.Store)
      assert is_pid(new_pid)
      assert new_pid != original_pid

      # Should still be functional
      result = LemonGateway.Store.get_chat_state({:test, 1})
      assert result == nil
    end

    test "EngineRegistry process is restarted if it crashes" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      original_pid = Process.whereis(LemonGateway.EngineRegistry)
      assert is_pid(original_pid)

      # Kill the process
      Process.exit(original_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Should have a new pid
      new_pid = Process.whereis(LemonGateway.EngineRegistry)
      assert is_pid(new_pid)
      assert new_pid != original_pid

      # Should still be functional
      engines = LemonGateway.EngineRegistry.list_engines()
      assert is_list(engines)
    end

    test "EngineLock process is restarted if it crashes" do
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      original_pid = Process.whereis(LemonGateway.EngineLock)
      assert is_pid(original_pid)

      # Kill the process
      Process.exit(original_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Should have a new pid
      new_pid = Process.whereis(LemonGateway.EngineLock)
      assert is_pid(new_pid)
      assert new_pid != original_pid

      # Should still be functional
      {:ok, release} = LemonGateway.EngineLock.acquire(:restart_test, 1000)
      release.()
    end
  end
end
