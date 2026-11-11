defmodule LemonCore.ServiceTest do
  use ExUnit.Case, async: true
  alias LemonCore.Service
  alias LemonCore.Service.{Role, Unit}
  @moduletag :tmp_dir
  @started "Tue Nov 10 12:00:00 2026"

  setup %{tmp_dir: home} do
    {:ok, state} =
      Agent.start_link(fn ->
        %{loaded: false, alive: false, calls: [], gui: true, bus: true, linger: "no"}
      end)

    runner = fn command, args, _ ->
      Agent.update(state, &%{&1 | calls: [{command, args} | &1.calls]})
      snapshot = Agent.get(state, & &1)

      case {command, args} do
        {"launchctl", ["print", "gui/501"]} ->
          {"", if(snapshot.gui, do: 0, else: 1)}

        {"launchctl", ["print", _]} ->
          if snapshot.loaded,
            do:
              {if(snapshot.alive,
                 do: "state = running\npid = 123\n",
                 else: "state = waiting\nlast exit code = 0\n"
               ), 0},
            else: {"", 1}

        {"launchctl", ["bootstrap" | _]} ->
          Agent.update(state, &%{&1 | loaded: true, alive: true})
          {"", 0}

        {"launchctl", ["bootout" | _]} ->
          Agent.update(state, &%{&1 | loaded: false, alive: false})
          {"", 0}

        {"launchctl", ["kickstart" | _]} ->
          Agent.update(state, &%{&1 | alive: true})
          {"", 0}

        {"launchctl", ["kill" | _]} ->
          Agent.update(state, &%{&1 | alive: false})
          {"", 0}

        {"systemctl", ["--user", "show-environment"]} ->
          {"", if(snapshot.bus, do: 0, else: 1)}

        {"loginctl", ["show-user" | _]} ->
          {snapshot.linger, 0}

        {"loginctl", ["enable-linger"]} ->
          Agent.update(state, &%{&1 | linger: "yes"})
          {"", 0}

        {"ps", ["-axo" | _]} ->
          {"", 0}

        {"ps", ["-p", "123", "-o", "lstart="]} ->
          if(snapshot.alive, do: {@started, 0}, else: {"", 1})

        {"ps", _} ->
          {"501 #{@started} /bin/beam.smp\n", 0}

        {_, ["__update-daemon", "snapshot"]} ->
          {"stopped\n", 0}

        {_, args} ->
          if "--enroll-only" in args, do: {"", 0}, else: {"", 1}
      end
    end

    opts = [
      home: home,
      os: :darwin,
      uid: "501",
      env: %{},
      login_path: "/usr/bin:/bin",
      command_runner: runner,
      wait: 0,
      name: "studio",
      controller: "ws://127.0.0.1:4044/ws",
      status_reader: fn _ -> {:ok, %{"state" => "online", "osPid" => 123, "reason" => nil}} end
    ]

    {:ok, opts: opts, state: state}
  end

  test "manager detection and persistence are truthful", %{opts: opts, state: state} do
    assert {"launchd", _, nil} = Service.manager(opts)
    Agent.update(state, &%{&1 | gui: false})
    assert {"launchd", _, :gui_session_required} = Service.manager(opts)

    assert {:ok, %{units: [%{state: "blocked", detail: "gui_session_required"}]}} =
             Service.install(["worker"], opts)

    linux = Keyword.put(opts, :os, :linux)

    assert {:ok, %{manager: "systemd", persistence: "session", linger: false}} =
             Service.status([], linux)

    Agent.update(state, &%{&1 | linger: "yes"})
    assert {:ok, %{persistence: "boot", linger: true}} = Service.status([], linux)
    Agent.update(state, &%{&1 | bus: false})
    assert {:ok, %{manager: "none", persistence: "none", linger: nil}} = Service.status([], linux)
    assert {"none", _, nil} = Service.manager(Keyword.put(opts, :manual, true))
  end

  test "unreachable native managers cannot hide installed units", %{opts: opts, state: state} do
    linux = Keyword.put(opts, :os, :linux)
    {:ok, spec} = Role.build("worker", "systemd", linux)
    :ok = Unit.write(spec, "systemd")
    Agent.update(state, &%{&1 | bus: false})
    assert {:error, :service_manager_unavailable} = Service.running_units(linux)
    assert {:error, :service_manager_unavailable} = Service.status([], linux)
    assert {:error, :service_manager_unavailable} = Service.install(["worker"], linux)
  end

  test "corrupt discovered units fail the update inventory closed", %{opts: opts} do
    {:ok, spec} = Role.build("worker", "launchd", opts)
    File.mkdir_p!(Path.dirname(spec.path))
    File.write!(spec.path, "invalid unit")
    assert {:error, :service_state_unavailable} = Service.running_units(opts)
  end

  test "uninstall binds the previewed unit bytes inside the operation lock", %{
    opts: opts,
    state: state
  } do
    assert {:ok, _} = Service.install(["worker"], opts)
    Agent.update(state, &%{&1 | calls: []})

    assert {:ok, %{units: [%{installed: true, state: "blocked", detail: "unit_changed"}]}} =
             Service.uninstall(
               ["worker"],
               Keyword.put(opts, :expected_fingerprint, String.duplicate("0", 64))
             )

    refute Enum.any?(Agent.get(state, & &1.calls), fn {command, args} ->
             command == "launchctl" and List.first(args) == "bootout"
           end)
  end

  test "second identical install is unchanged without bootout", %{opts: opts, state: state} do
    assert {:ok, %{units: [%{state: "online", action: "created"}]}} =
             Service.install(["worker"], opts)

    Agent.update(state, &%{&1 | calls: []})

    assert {:ok, %{units: [%{state: "online", action: "unchanged"}]}} =
             Service.install(["worker"], opts)

    refute Enum.any?(Agent.get(state, & &1.calls), fn {command, args} ->
             command == "launchctl" and List.first(args) == "bootout"
           end)
  end

  test "changing owned content rewrites the unit", %{opts: opts} do
    assert {:ok, _} = Service.install(["worker"], opts)
    changed = Keyword.put(opts, :allowed_root, opts[:home])

    assert {:ok, %{units: [%{action: "updated", state: "online"}]}} =
             Service.install(["worker"], changed)
  end

  test "legacy worker labels are adopted in place", %{opts: opts} do
    {:ok, spec} = Role.build("worker", "launchd", opts)
    File.mkdir_p!(Path.dirname(spec.path))

    body =
      Unit.render(spec, "launchd")
      |> String.replace("<dict><key>SuccessfulExit</key><false/></dict>", "<true/>")

    File.write!(spec.path, body)

    assert {:ok,
            %{units: [%{label: "org.lemon.node.studio", action: "adopted", state: "online"}]}} =
             Service.install(["worker"], opts)
  end

  test "foreign unit stays byte-for-byte unchanged and unsignalled", %{opts: opts, state: state} do
    {:ok, spec} = Role.build("worker", "launchd", opts)
    File.mkdir_p!(Path.dirname(spec.path))
    body = Unit.render(%{spec | argv: ["/bin/sleep", "100"]}, "launchd")
    File.write!(spec.path, body)

    assert {:ok, %{units: [%{state: "foreign", detail: "unit_foreign"}]}} =
             Service.install(["worker"], opts)

    assert File.read!(spec.path) == body

    refute Enum.any?(Agent.get(state, & &1.calls), fn {command, args} ->
             command == "kill" or
               (command == "launchctl" and List.first(args) in ["bootout", "bootstrap"])
           end)
  end

  test "repair recovers saved controller options and uninstall keeps credentials", %{opts: opts} do
    assert {:ok, _} = Service.install(["worker"], opts)
    saved = Path.join(opts[:home], ".lemon/nodes/execution/credential.json")
    File.mkdir_p!(Path.dirname(saved))
    File.write!(saved, "credential fixture")

    assert {:ok, %{units: [%{state: "online"}]}} =
             Service.repair(["worker"], Keyword.delete(opts, :controller))

    assert {:ok, %{units: [%{installed: false, action: "removed"}]}} =
             Service.uninstall(["worker"], opts)

    assert File.read!(saved) == "credential fixture"
  end

  test "enrollment sends code once through stdin, not argv or environment", %{opts: opts} do
    parent = self()
    original = opts[:command_runner]

    runner = fn executable, args, command_opts ->
      if "--enroll-only" in args, do: send(parent, {:enroll, args, command_opts})
      original.(executable, args, command_opts)
    end

    code = String.duplicate("x", 43)
    opts = Keyword.merge(opts, command_runner: runner, invite_code: code)
    assert {:ok, %{units: [%{state: "online"}]}} = Service.install(["worker"], opts)
    assert_receive {:enroll, args, command_opts}
    refute Enum.any?(args, &String.contains?(&1, code))
    assert command_opts[:input] == code <> "\n"
    refute_received {:enroll, _, _}
  end

  test "uncertain enrollment never installs or retries", %{opts: opts} do
    original = opts[:command_runner]

    runner = fn executable, args, command_opts ->
      if "--enroll-only" in args,
        do: {"enrollment_outcome_unknown", 1},
        else: original.(executable, args, command_opts)
    end

    opts = Keyword.merge(opts, command_runner: runner, invite_code: String.duplicate("x", 43))

    assert {:ok,
            %{
              units: [%{installed: false, state: "blocked", detail: "enrollment_outcome_unknown"}]
            }} = Service.install(["worker"], opts)
  end

  test "waiting returns a bounded timeout instead of claiming online", %{opts: opts} do
    opts =
      Keyword.merge(opts,
        wait: 1,
        status_reader: fn _ ->
          {:ok, %{"state" => "reconnecting", "osPid" => 123, "reason" => nil}}
        end
      )

    assert {:ok, %{units: [%{state: "reconnecting", detail: "timeout"}]}} =
             Service.install(["worker"], opts)
  end

  test "manual units remain discoverable when a native manager is available", %{opts: opts} do
    {:ok, spec} = Role.build("worker", "none", opts)
    :ok = Unit.write(spec, "none")
    hash = :crypto.hash(:sha256, Jason.encode!(spec.argv)) |> Base.encode16(case: :lower)
    record = %{pid: 123, startedAt: @started, argvHash: hash}
    path = LemonCore.Service.Manual.record_path(spec, opts)
    File.write!(path, Jason.encode!(record))
    File.chmod!(path, 0o600)

    assert {:ok, %{manager: "none", persistence: "none", units: [%{state: "online"}]}} =
             Service.status(["worker"], opts)

    assert [%{manager: "none", role: "worker"}] = Service.running_units(opts)
  end

  test "controller adoption quiesces workers before stopping the detached runtime", %{opts: opts} do
    {:ok, worker_spec} = Role.build("worker", "launchd", opts)
    :ok = Unit.write(worker_spec, "launchd")
    {:ok, state} = Agent.start_link(fn -> %{worker: true, controller: false, events: []} end)
    event = fn name -> Agent.update(state, &%{&1 | events: &1.events ++ [name]}) end
    pid_file = Path.join(opts[:home], ".lemon/run/lemon-4040.pid")

    runner = fn
      "launchctl", ["print", "gui/501"], _ ->
        {"", 0}

      "launchctl", ["print", "gui/501/org.lemon.node.studio"], _ ->
        {if(Agent.get(state, & &1.worker), do: "pid = 123\n", else: "last exit code = 0\n"), 0}

      "launchctl", ["print", "gui/501/org.lemon.controller"], _ ->
        if Agent.get(state, & &1.controller), do: {"pid = 124\n", 0}, else: {"", 1}

      "launchctl", ["kill", "SIGTERM", "gui/501/org.lemon.node.studio"], _ ->
        event.(:stop_worker)
        Agent.update(state, &%{&1 | worker: false})
        {"", 0}

      "launchctl", ["bootstrap", "gui/501", _], _ ->
        event.(:start_controller)
        Agent.update(state, &%{&1 | controller: true})
        File.mkdir_p!(Path.dirname(pid_file))
        File.write!(pid_file, "124\n")
        {"", 0}

      "launchctl", ["kickstart", "gui/501/org.lemon.node.studio"], _ ->
        event.(:start_worker)
        Agent.update(state, &%{&1 | worker: true})
        {"", 0}

      "ps", ["-p", "123", "-o", "lstart="], _ ->
        {"", 1}

      "ps", _, _ ->
        {"501 #{@started} /bin/beam.smp\n", 0}

      _, ["__update-daemon", "snapshot"], _ ->
        {String.duplicate("a", 64), 0}

      _, ["__update-daemon", "stop", _], _ ->
        event.(:stop_controller)
        {"", 0}
    end

    opts =
      Keyword.merge(opts, command_runner: runner, http_get: fn _ -> {:ok, %{"ok" => true}} end)

    assert {:ok, %{units: [%{state: "ready", action: "adopted"}]}} =
             Service.install(["controller"], opts)

    assert Agent.get(state, & &1.events) == [
             :stop_worker,
             :stop_controller,
             :start_controller,
             :start_worker
           ]
  end
end
