defmodule LemonCore.Update.DaemonTest do
  use ExUnit.Case, async: false

  alias LemonCore.Update.Daemon

  @moduletag :tmp_dir

  @token String.duplicate("a", 64)

  defp install_launcher!(tmp_dir, version, snapshot_output, restart_status) do
    home = Path.join(tmp_dir, "home")
    bin = Path.join([home, ".lemon", "versions", version, "bin"])
    File.mkdir_p!(bin)
    path = Path.join(bin, "lemon")

    File.write!(path, """
    #!/bin/sh
    case "$1:$2" in
      __update-daemon:snapshot) echo #{snapshot_output} ;;
      __update-daemon:restart)
        printf 'controller\\n' >> "#{Path.join(tmp_dir, "order")}"
        exit #{restart_status}
        ;;
      *) exit 96 ;;
    esac
    """)

    File.chmod!(path, 0o755)
    home
  end

  defp recorder(tmp_dir, label, result) do
    fn units, _opts ->
      File.write!(
        Path.join(tmp_dir, "order"),
        "#{label}:#{Enum.map_join(units, ",", & &1.name)}\n",
        [:append]
      )

      result
    end
  end

  defp order(tmp_dir) do
    case File.read(Path.join(tmp_dir, "order")) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp worker(name), do: %{role: "worker", name: name, spec: %{argv: ["node", "join"]}}
  defp backend_unit, do: %{role: "backend", name: nil, spec: %{argv: ["lemon-bot"]}}

  defp base_opts(tmp_dir, home) do
    [
      paths_opts: [home_dir: home],
      release_command_env: [],
      stop_units_fun: recorder(tmp_dir, "stop", :ok),
      start_units_fun: recorder(tmp_dir, "start", :ok),
      restart_units_fun: recorder(tmp_dir, "restart_backend", :ok)
    ]
  end

  describe "snapshot/2" do
    test "records the running worker and backend units beside the controller token", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2020.01.0", @token, 0)

      opts = [
        paths_opts: [home_dir: home],
        release_command_env: [],
        service_running_units: [worker("chico"), backend_unit()]
      ]

      assert {:ok, snapshot} = Daemon.snapshot("2020.01.0", opts)
      assert snapshot.controller == @token
      assert [%{name: "chico"}] = snapshot.workers
      assert %{role: "backend"} = snapshot.backend
      assert snapshot.backend_installed?
    end

    test "reports no units and no installed backend without a service manager", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2020.01.0", "stopped", 0)

      opts = [
        paths_opts: [home_dir: home],
        release_command_env: [],
        service_running_units: [],
        backend_unit_installed: false
      ]

      assert {:ok, %{controller: :stopped, workers: [], backend: nil, backend_installed?: false}} =
               Daemon.snapshot("2020.01.0", opts)
    end

    test "refuses an unverifiable controller before any unit is inspected", %{tmp_dir: tmp_dir} do
      home = install_launcher!(tmp_dir, "2020.01.0", "foreign", 0)

      opts = [
        paths_opts: [home_dir: home],
        release_command_env: [],
        service_running_units: [worker("chico")]
      ]

      assert {:error, :daemon_ownership_unverified} = Daemon.snapshot("2020.01.0", opts)
    end
  end

  describe "restart/5 ordering" do
    test "stops workers, restarts the controller, starts workers, then restarts the backend", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2099.01.0", @token, 0)
      _ = install_launcher!(tmp_dir, "2020.01.0", @token, 0)

      snapshot = %{
        controller: @token,
        workers: [worker("chico"), worker("tito")],
        backend: backend_unit(),
        backend_installed?: true
      }

      assert {:ok, result} =
               Daemon.restart(
                 %{staged: "2099.01.0"},
                 snapshot,
                 "2020.01.0",
                 "2099.01.0",
                 base_opts(tmp_dir, home)
               )

      assert order(tmp_dir) == [
               "stop:chico,tito",
               "controller",
               "start:chico,tito",
               "restart_backend:"
             ]

      assert result.restart == "restarted"
      assert result.workers == "restarted"
      assert result.backend == "restarted"
      refute result.restart_required
    end

    test "workers resume once the asynchronous controller replacement is ready", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2099.01.0", @token, 0)
      parent = self()

      runner = fn _launcher, ["__update-daemon", "restart" | _], _opts ->
        send(parent, {:waiting_for_replacement, self()})

        receive do
          :replacement_ready -> {"replacement ready", 0}
        end
      end

      opts = base_opts(tmp_dir, home) |> Keyword.put(:command_runner, runner)

      snapshot = %{
        controller: @token,
        workers: [worker("chico")],
        backend: backend_unit(),
        backend_installed?: true
      }

      task = Task.async(fn -> Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", opts) end)
      assert_receive {:waiting_for_replacement, waiter}
      assert order(tmp_dir) == ["stop:chico"]
      send(waiter, :replacement_ready)

      assert {:ok, %{workers: "restarted", backend: "restarted", restart_required: false}} =
               Task.await(task)

      assert order(tmp_dir) == ["stop:chico", "start:chico", "restart_backend:"]
    end

    test "a stopped controller still cycles the running units without starting a daemon", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2099.01.0", "stopped", 0)

      snapshot = %{
        controller: :stopped,
        workers: [worker("chico")],
        backend: nil,
        backend_installed?: true
      }

      assert {:ok, result} =
               Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", base_opts(tmp_dir, home))

      assert order(tmp_dir) == ["stop:chico", "start:chico"]
      assert result.restart == "not_running"
      assert result.workers == "restarted"
      assert result.backend == "not_running"
    end

    test "units that were not running are never started", %{tmp_dir: tmp_dir} do
      home = install_launcher!(tmp_dir, "2099.01.0", @token, 0)
      _ = install_launcher!(tmp_dir, "2020.01.0", @token, 0)

      snapshot = %{
        controller: @token,
        workers: [],
        backend: nil,
        backend_installed?: true
      }

      assert {:ok, result} =
               Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", base_opts(tmp_dir, home))

      assert order(tmp_dir) == ["controller"]
      assert result.workers == "not_running"
      assert result.backend == "not_running"
    end

    test "reports a never-installed backend apart from a stopped one", %{tmp_dir: tmp_dir} do
      home = install_launcher!(tmp_dir, "2099.01.0", "stopped", 0)

      snapshot = %{controller: :stopped, workers: [], backend: nil, backend_installed?: false}

      assert {:ok, %{backend: "not_installed"}} =
               Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", base_opts(tmp_dir, home))
    end
  end

  describe "restart/5 failures" do
    test "a failed controller restart leaves workers and the backend down", %{tmp_dir: tmp_dir} do
      home = install_launcher!(tmp_dir, "2099.01.0", @token, 1)
      _ = install_launcher!(tmp_dir, "2020.01.0", @token, 1)

      snapshot = %{
        controller: @token,
        workers: [worker("chico")],
        backend: backend_unit(),
        backend_installed?: true
      }

      assert {:error, {:daemon_restart_failed, result}} =
               Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", base_opts(tmp_dir, home))

      assert order(tmp_dir) == ["stop:chico", "controller"]
      assert result.restart == "failed"
      assert result.workers == "failed"
      assert result.backend == "failed"
      assert result.restart_required
    end

    test "a worker that refuses to stop aborts the controller and backend restarts", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2099.01.0", @token, 0)
      _ = install_launcher!(tmp_dir, "2020.01.0", @token, 0)

      opts =
        tmp_dir
        |> base_opts(home)
        |> Keyword.put(:stop_units_fun, recorder(tmp_dir, "stop", {:error, :unit_foreign}))

      snapshot = %{
        controller: @token,
        workers: [worker("chico")],
        backend: backend_unit(),
        backend_installed?: true
      }

      assert {:error, {:daemon_restart_failed, result}} =
               Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", opts)

      assert order(tmp_dir) == ["stop:chico"]
      assert result.restart == "failed"
      assert result.workers == "failed"
      assert result.backend == "failed"
      assert result.restart_required
    end

    test "a stopped controller is still reported not_running when workers refuse to stop", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2099.01.0", "stopped", 0)

      opts =
        tmp_dir
        |> base_opts(home)
        |> Keyword.put(:stop_units_fun, recorder(tmp_dir, "stop", {:error, :unit_foreign}))

      snapshot = %{
        controller: :stopped,
        workers: [worker("chico")],
        backend: nil,
        backend_installed?: true
      }

      assert {:error, {:daemon_restart_failed, result}} =
               Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", opts)

      assert order(tmp_dir) == ["stop:chico"]
      assert result.restart == "not_running"
      assert result.workers == "failed"
    end

    test "a backend restart failure does not mask a healthy controller and workers", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2099.01.0", @token, 0)
      _ = install_launcher!(tmp_dir, "2020.01.0", @token, 0)

      opts =
        tmp_dir
        |> base_opts(home)
        |> Keyword.put(
          :restart_units_fun,
          recorder(tmp_dir, "restart_backend", {:error, :service_command_failed})
        )

      snapshot = %{
        controller: @token,
        workers: [worker("chico")],
        backend: backend_unit(),
        backend_installed?: true
      }

      assert {:error, {:daemon_restart_failed, result}} =
               Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", opts)

      assert result.restart == "restarted"
      assert result.workers == "restarted"
      assert result.backend == "failed"
      assert result.restart_required
    end

    test "an unexpected unit-operation return fails closed instead of counting as done", %{
      tmp_dir: tmp_dir
    } do
      home = install_launcher!(tmp_dir, "2099.01.0", @token, 0)
      _ = install_launcher!(tmp_dir, "2020.01.0", @token, 0)

      opts =
        tmp_dir
        |> base_opts(home)
        |> Keyword.put(:start_units_fun, recorder(tmp_dir, "start", :who_knows))

      snapshot = %{
        controller: @token,
        workers: [worker("chico")],
        backend: nil,
        backend_installed?: true
      }

      assert {:error, {:daemon_restart_failed, result}} =
               Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", opts)

      assert result.workers == "failed"
    end
  end

  test "every controller call goes through the injected command runner", %{tmp_dir: tmp_dir} do
    home = install_launcher!(tmp_dir, "2099.01.0", @token, 0)
    _ = install_launcher!(tmp_dir, "2020.01.0", @token, 0)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    runner = fn executable, args, system_opts ->
      Agent.update(calls, &[{executable, args, Keyword.keys(system_opts)} | &1])
      {"#{@token}\n", 0}
    end

    opts = [
      paths_opts: [home_dir: home],
      release_command_env: [],
      command_runner: runner,
      service_running_units: [],
      backend_unit_installed: false
    ]

    assert {:ok, snapshot} = Daemon.snapshot("2020.01.0", opts)
    assert snapshot.controller == @token

    assert {:ok, %{restart: "restarted"}} =
             Daemon.restart(%{}, snapshot, "2020.01.0", "2099.01.0", opts)

    recorded = Agent.get(calls, & &1) |> Enum.reverse()

    assert [
             {_, ["__update-daemon", "snapshot"], first},
             {_, ["__update-daemon", "restart" | _], _}
           ] = recorded

    assert :env in first and :stderr_to_stdout in first
    refute File.exists?(Path.join(tmp_dir, "order"))
  end

  test "an inventory the service layer refuses propagates instead of looking empty", %{
    tmp_dir: tmp_dir
  } do
    home = install_launcher!(tmp_dir, "2020.01.0", @token, 0)

    base = [paths_opts: [home_dir: home], release_command_env: []]

    for reason <- [:service_manager_unavailable, :gui_session_required] do
      assert {:error, ^reason} =
               Daemon.snapshot(
                 "2020.01.0",
                 Keyword.put(base, :service_running_units, {:error, reason})
               )
    end

    assert {:error, :unit_inventory_unavailable} =
             Daemon.snapshot("2020.01.0", Keyword.put(base, :service_running_units, :whatever))
  end

  test "an unreadable backend unit status refuses the snapshot", %{tmp_dir: tmp_dir} do
    home = install_launcher!(tmp_dir, "2020.01.0", @token, 0)

    opts = [
      paths_opts: [home_dir: home],
      release_command_env: [],
      service_running_units: [],
      backend_unit_installed: :unknown
    ]

    assert {:error, :invalid_unit_snapshot} = Daemon.snapshot("2020.01.0", opts)
  end
end
