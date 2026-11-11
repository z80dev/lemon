defmodule LemonCore.Service.TakeoverTest do
  use ExUnit.Case, async: true
  alias LemonCore.Service.{Identity, Readiness, Takeover}
  @moduletag :tmp_dir
  @started "Tue Nov 10 12:00:00 2026"
  @manager %{loaded: false, pid: nil, failed: false}

  test "stopped controller does not signal and authenticated takeover binds the token", %{
    tmp_dir: home
  } do
    spec = %{role: "controller", port: 4040}
    token = String.duplicate("a", 64)
    parent = self()

    for snapshot <- ["stopped", token] do
      runner = fn _, args, _ ->
        send(parent, {:command, args})
        {if(args == ["__update-daemon", "snapshot"], do: snapshot, else: ""), 0}
      end

      assert {:ok, adopted} = Takeover.prepare(spec, @manager, home: home, command_runner: runner)
      assert adopted == (snapshot == token)
      assert_receive {:command, ["__update-daemon", "snapshot"]}
      if adopted, do: assert_receive({:command, ["__update-daemon", "stop", ^token]})
      refute_received {:command, _}
    end
  end

  test "ownership failures never stop a controller", %{tmp_dir: home} do
    parent = self()

    runner = fn _, args, _ ->
      send(parent, {:command, args})
      {"restore_in_progress", 1}
    end

    assert {:error, :restore_in_progress} =
             Takeover.prepare(%{role: "controller", port: 4040}, @manager,
               home: home,
               command_runner: runner
             )

    assert_receive {:command, ["__update-daemon", "snapshot"]}
    refute_received {:command, _}
  end

  test "backend record verifies instance, birth time and uid before SIGTERM", %{tmp_dir: home} do
    spec = %{role: "backend", port: 4100, env: %{}, argv: [home <> "/.local/bin/lemon-bot"]}
    path = Readiness.backend_record(spec, home: home)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{pid: 123, startedAt: @started, instanceId: "ours"}))
    File.chmod!(path, 0o600)
    {:ok, state} = Agent.start_link(fn -> %{alive: true, signals: []} end)

    runner = fn
      "lsof", _, _ ->
        {"p123\n", 0}

      "ps", ["-p", "123", "-o", "lstart="], _ ->
        if Agent.get(state, & &1.alive), do: {@started, 0}, else: {"", 1}

      "ps", _, _ ->
        {"501 #{@started} /bin/backend\n", 0}

      "kill", args, _ ->
        Agent.update(state, &%{&1 | alive: false, signals: [args | &1.signals]})
        {"", 0}
    end

    opts = [
      home: home,
      uid: "501",
      command_runner: runner,
      http_get: fn _ -> {:ok, %{"product" => "lemon_bot", "instanceId" => "ours"}} end
    ]

    assert {:ok, true} = Takeover.prepare(spec, @manager, opts)
    assert Agent.get(state, & &1.signals) == [["-TERM", "123"]]
  end

  test "legacy backend outside managed binaries or wrong uid is blocked", %{tmp_dir: home} do
    spec = %{role: "backend", port: 4100, env: %{}, argv: [home <> "/.local/bin/lemon-bot"]}

    for {uid, program} <- [
          {"502", home <> "/.lemon/lemon_bot/versions/v/bin/lemon-bot"},
          {"501", "/tmp/foreign"}
        ] do
      parent = self()

      runner = fn
        "lsof", _, _ ->
          {"p123\n", 0}

        "ps", _, _ ->
          {"#{uid} #{@started} #{program}\n", 0}

        "kill", _, _ ->
          send(parent, :signalled)
          {"", 0}
      end

      opts = [
        home: home,
        uid: "501",
        command_runner: runner,
        http_get: fn _ -> {:ok, %{"product" => "lemon_bot", "instanceId" => "ours"}} end
      ]

      assert {:error, :port_in_use_foreign} = Takeover.prepare(spec, @manager, opts)
      refute_received :signalled
    end
  end

  test "Linux listener discovery does not require lsof and fails closed on unresolved sockets", %{
    tmp_dir: home
  } do
    proc_root = Path.join(home, "proc")
    File.mkdir_p!(Path.join(proc_root, "net"))
    File.mkdir_p!(Path.join([proc_root, "321", "fd"]))

    File.write!(
      Path.join([proc_root, "net", "tcp"]),
      "sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n" <>
        "0: 0100007F:1004 00000000:0000 0A 0:0 0:0 0 501 0 9001\n"
    )

    descriptor = Path.join([proc_root, "321", "fd", "7"])
    File.ln_s!("socket:[9001]", descriptor)
    parent = self()

    runner = fn command, _, _ ->
      send(parent, {:command, command})
      {"", 127}
    end

    opts = [os: :linux, proc_root: proc_root, command_runner: runner]
    assert Identity.listeners(4100, opts) == [321]
    refute_received {:command, "lsof"}

    File.rm!(descriptor)
    assert Identity.listeners(4100, opts) == :unknown
    refute_received {:command, "lsof"}
  end

  test "legacy worker matcher never selects other names or uids", %{tmp_dir: home} do
    program = home <> "/.lemon/versions/v/erts-16/bin/beam.smp"

    lines =
      for {pid, uid, name} <- [
            {123, 501, "studio"},
            {124, 501, "studio-other"},
            {125, 502, "studio"}
          ],
          do:
            "#{pid} #{uid} #{@started} #{program} -- node join --name #{name} --controller ws://127.0.0.1:4044/ws"

    runner = fn
      "ps", ["-axo", _], _ -> {Enum.join(lines, "\n"), 0}
      "ps", _, _ -> {"501 #{@started} #{program}\n", 0}
    end

    assert [%{pid: 123}] =
             Identity.legacy_workers("studio", home: home, uid: "501", command_runner: runner)
  end

  test "changed start identity refuses the signal" do
    parent = self()

    runner = fn
      "ps", _, _ ->
        {"501 Tue Nov 10 13:00:00 2026 /bin/worker\n", 0}

      "kill", _, _ ->
        send(parent, :signalled)
        {"", 0}
    end

    identity = %{pid: 123, started_at: @started, executable: "/bin/worker"}

    assert {:error, :process_identity_changed} =
             Identity.terminate(identity, uid: "501", command_runner: runner)

    refute_received :signalled
  end
end
