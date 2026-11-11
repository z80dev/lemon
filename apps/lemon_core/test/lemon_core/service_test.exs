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

  test "controller and backend retain their installed environment across callers", %{
    opts: opts,
    state: state
  } do
    bot = Path.join(opts[:home], ".local/bin/lemon-bot")
    File.mkdir_p!(Path.dirname(bot))
    File.write!(bot, "#!/bin/sh\nexit 0\n")
    File.chmod!(bot, 0o700)
    pid_file = Path.join(opts[:home], ".lemon/run/lemon-4040.pid")
    File.mkdir_p!(Path.dirname(pid_file))
    File.write!(pid_file, "123\n")
    record = Path.join(opts[:home], ".lemon/lemon_bot/run/lemon-bot-4100.json")
    File.mkdir_p!(Path.dirname(record))
    File.write!(record, Jason.encode!(%{pid: 123, startedAt: @started, instanceId: "ours"}))
    File.chmod!(record, 0o600)

    opts =
      Keyword.merge(opts,
        http_get: fn url ->
          if String.ends_with?(url, "/healthz"),
            do: {:ok, %{"ok" => true}},
            else: {:ok, %{"product" => "lemon_bot", "instanceId" => "ours"}}
        end
      )

    assert {:ok, %{units: [_, _]}} = Service.install(["controller", "backend"], opts)
    Agent.update(state, &%{&1 | calls: []})

    other =
      Keyword.merge(opts,
        login_path: "/different/shell/bin:/bin",
        env: %{"PATH" => "/other/bin", "LANG" => "C", "SHELL" => "/different/shell"}
      )

    assert {:ok, %{units: [%{action: "unchanged"}, %{action: "unchanged"}]}} =
             Service.install(["controller", "backend"], other)

    refute Enum.any?(Agent.get(state, & &1.calls), fn {command, args} ->
             command == "launchctl" and
               List.first(args) in ["bootstrap", "bootout", "kickstart", "kill"]
           end)
  end

  test "worker status exposes the persisted execution wrapper for setup repair", %{opts: opts} do
    assert {:ok, %{units: [%{execWrapper: nil}]}} = Service.install(["worker"], opts)
    wrapper = Path.join(opts[:home], "Lemon Bot.app/Contents/MacOS/worker-helper")
    File.mkdir_p!(Path.dirname(wrapper))
    File.write!(wrapper, "#!/bin/sh\nexec \"$@\"\n")
    File.chmod!(wrapper, 0o755)

    assert {:ok, %{units: [%{execWrapper: ^wrapper, state: "online"}]}} =
             Service.repair(["worker"], Keyword.put(opts, :exec_wrapper, wrapper))

    assert {:ok, %{units: [%{execWrapper: ^wrapper}]}} = Service.status(["worker"], opts)
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
    env = Map.new(command_opts[:env])
    assert env["LEMON_GATEWAY_HEALTH_PORT"] == "0"
    assert env["LEMON_ROUTER_HEALTH_PORT"] == "0"
    assert env["HOME"] == opts[:home]
    refute inspect(env) =~ code
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

  test "enrollment distinguishes rejection, startup failure and uncertain consumption", %{
    opts: opts
  } do
    original = opts[:command_runner]

    for {response, detail} <- [
          {{"lemon node join: invite_rejected\n", 2}, "invite_rejected"},
          {{"lemon node join: enroll_start_failed\n", 2}, "enroll_start_failed"},
          {{"", 127}, "enroll_start_failed"},
          {{"local or remote failure with private-credential", 2}, "enrollment_outcome_unknown"},
          {{"lemon node join: enrollment_outcome_unknown\n", 1}, "enrollment_outcome_unknown"}
        ] do
      runner = fn executable, args, command_opts ->
        if "--enroll-only" in args, do: response, else: original.(executable, args, command_opts)
      end

      attempt =
        Keyword.merge(opts, command_runner: runner, invite_code: String.duplicate("x", 43))

      assert {:ok, %{units: [%{installed: false, state: "blocked", detail: ^detail}]}} =
               Service.install(["worker"], attempt)
    end
  end

  test "enrollment can bind its health listeners while controller health ports are occupied", %{
    opts: opts
  } do
    {:ok, gateway} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, router} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)

    on_exit(fn ->
      :gen_tcp.close(gateway)
      :gen_tcp.close(router)
    end)

    {:ok, {_, gateway_port}} = :inet.sockname(gateway)
    {:ok, {_, router_port}} = :inet.sockname(router)
    launcher = Path.join(opts[:home], ".lemon/bin/lemon")
    File.mkdir_p!(Path.dirname(launcher))

    File.write!(launcher, """
    #!/usr/bin/env elixir
    for {key, occupied} <- [{"LEMON_GATEWAY_HEALTH_PORT", #{gateway_port}}, {"LEMON_ROUTER_HEALTH_PORT", #{router_port}}] do
      port = System.get_env(key, Integer.to_string(occupied)) |> String.to_integer()
      case :gen_tcp.listen(port, ip: {127, 0, 0, 1}, active: false) do
        {:ok, _socket} -> :ok
        {:error, _} -> System.halt(2)
      end
    end
    if byte_size(IO.read(:stdio, 45)) != 44, do: System.halt(2)
    """)

    File.chmod!(launcher, 0o700)
    original = opts[:command_runner]

    runner = fn executable, args, command_opts ->
      if "--enroll-only" in args,
        do: LemonCore.Service.Command.run(executable, args, [], command_opts),
        else: original.(executable, args, command_opts)
    end

    path = Enum.map_join(["elixir", "erl"], ":", &(System.find_executable(&1) |> Path.dirname()))

    attempt =
      Keyword.merge(opts,
        launcher: launcher,
        command_runner: runner,
        login_path: path <> ":/usr/bin:/bin",
        env: %{
          "LEMON_GATEWAY_HEALTH_PORT" => to_string(gateway_port),
          "LEMON_ROUTER_HEALTH_PORT" => to_string(router_port)
        },
        invite_code: String.duplicate("x", 43)
      )

    assert {:ok, %{units: [%{state: "online"}]}} = Service.install(["worker"], attempt)
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
