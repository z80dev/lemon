defmodule LemonCli.ServiceCommandTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias LemonCli.{CLI, ServiceCommand}
  alias LemonCore.Service.{Role, Unit}
  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    # Like launchd, a booted-out service is no longer listed.
    booted_out = start_supervised!({Agent, fn -> MapSet.new() end})

    runner = fn
      "launchctl", ["print", "gui/501"], _ ->
        {"", 0}

      "launchctl", ["print", target], _ ->
        if Agent.get(booted_out, &MapSet.member?(&1, target)),
          do: {"", 1},
          else: {"pid = 123\n", 0}

      "launchctl", ["bootout", target], _ ->
        Agent.update(booted_out, &MapSet.put(&1, target))
        {"", 0}

      "ps", _, _ ->
        {"501 Tue Nov 10 12:00:00 2026 /bin/beam.smp\n", 0}

      _, _, _ ->
        {"", 1}
    end

    opts = [
      home: home,
      os: :darwin,
      uid: "501",
      env: %{},
      login_path: "/usr/bin:/bin",
      command_runner: runner,
      name: "studio",
      controller: "ws://127.0.0.1:4044/ws",
      status_reader: fn _ -> {:ok, %{"state" => "online", "osPid" => 123, "reason" => nil}} end
    ]

    {:ok, opts: opts}
  end

  test "invalid commands, names, roles and flags are usage failures" do
    args = [
      [],
      ["restart"],
      ["install"],
      ["uninstall"],
      ["install", "database"],
      ["install", "worker"],
      ["install", "worker", "--name", "bad name"],
      ["install", "worker", "--name", String.duplicate("a", 65)],
      ["install", "controller", "--wait", "-1"],
      ["status", "--bot", "/bin/bot"],
      ["install", "controller", "--invite-code-stdin"]
    ]

    for argv <- args do
      assert capture_io(:stderr, fn -> assert ServiceCommand.run(argv) == 2 end) =~ "Error:"
    end
  end

  test "bounded stdin rejects malformed or extra credential bytes" do
    for input <- [
          "",
          "short\n",
          String.duplicate("a", 42) <> "\n",
          String.duplicate("a", 44) <> "\n",
          String.duplicate("a", 42) <> "!\n",
          String.duplicate("a", 43) <> "\nextra"
        ] do
      capture_io(:stderr, fn ->
        capture_io([input: input], fn ->
          assert ServiceCommand.run([
                   "install",
                   "worker",
                   "--name",
                   "studio",
                   "--invite-code-stdin"
                 ]) == 2
        end)
      end)
    end
  end

  test "status emits exactly one schema 1 document and exits 0 for online", %{opts: opts} do
    {:ok, spec} = Role.build("worker", "launchd", opts)
    :ok = Unit.write(spec, "launchd")

    output =
      capture_io(fn ->
        assert ServiceCommand.run(["status", "worker", "--name", "studio", "--json"], opts) == 0
      end)

    assert {:ok,
            %{
              "schema" => 1,
              "manager" => "launchd",
              "persistence" => "login",
              "units" => [%{"state" => "online"}]
            }} = Jason.decode(output)

    assert length(String.split(String.trim(output), "\n")) == 1
  end

  test "install backend accepts the choice reload flag and restarts once", %{opts: opts} do
    bot = Path.join(opts[:home], ".local/bin/lemon-bot")
    File.mkdir_p!(Path.dirname(bot))
    File.write!(bot, "#!/bin/sh\nexit 0\n")
    File.chmod!(bot, 0o700)
    record = Path.join(opts[:home], ".lemon/lemon_bot/run/lemon-bot-4100.json")
    File.mkdir_p!(Path.dirname(record))

    # The replacement backend writes its own record; the old one ran as pid 123.
    File.write!(
      record,
      Jason.encode!(%{
        pid: 456,
        startedAt: "Tue Nov 10 12:00:00 2026",
        instanceId: "ours"
      })
    )

    File.chmod!(record, 0o600)
    caller = self()
    runner = opts[:command_runner]
    {:ok, restarted} = Agent.start_link(fn -> false end)

    opts =
      Keyword.merge(opts,
        wait: 0,
        http_get: fn _ -> {:ok, %{"product" => "lemon_bot", "instanceId" => "ours"}} end,
        command_runner: fn
          "launchctl", ["kickstart", "-k", "gui/501/org.lemon.bot"], _ ->
            Agent.update(restarted, fn _ -> true end)
            send(caller, :backend_restarted)
            {"", 0}

          "launchctl", ["print", "gui/501/org.lemon.bot"], _ ->
            {"pid = #{if Agent.get(restarted, & &1), do: 456, else: 123}\n", 0}

          command, args, options ->
            runner.(command, args, options)
        end
      )

    {:ok, spec} = Role.build("backend", "launchd", opts)
    :ok = Unit.write(spec, "launchd")

    output =
      capture_io(fn ->
        assert ServiceCommand.run(
                 ["install", "backend", "--restart-backend", "--json"],
                 opts
               ) == 0
      end)

    assert [%{"action" => "restarted", "state" => "ready"}] = Jason.decode!(output)["units"]
    assert_received :backend_restarted
    refute_received :backend_restarted
  end

  test "not-ready and foreign units exit 1", %{opts: opts} do
    {:ok, spec} = Role.build("worker", "launchd", opts)
    :ok = Unit.write(spec, "launchd")

    parked =
      Keyword.put(opts, :status_reader, fn _ ->
        {:ok,
         %{"state" => "needs_reauthorization", "osPid" => 123, "reason" => "session_expired"}}
      end)

    output =
      capture_io(fn ->
        assert ServiceCommand.run(["status", "worker", "--name", "studio", "--json"], parked) == 1
      end)

    assert [%{"state" => "needs_reauthorization"}] = Jason.decode!(output)["units"]
    :ok = Unit.write(%{spec | argv: ["/bin/sleep", "100"]}, "launchd")

    output =
      capture_io(fn ->
        assert ServiceCommand.run(["uninstall", "worker", "--name", "studio", "--json"], opts) ==
                 1
      end)

    assert [%{"state" => "foreign"}] = Jason.decode!(output)["units"]
  end

  test "uninstall success exits 0 and reports removal", %{opts: opts} do
    {:ok, spec} = Role.build("worker", "launchd", opts)
    :ok = Unit.write(spec, "launchd")

    output =
      capture_io(fn ->
        assert ServiceCommand.run(["uninstall", "worker", "--name", "studio", "--json"], opts) ==
                 0
      end)

    assert [%{"action" => "removed", "installed" => false}] = Jason.decode!(output)["units"]
  end

  test "human output reports the actual persistence and readiness", %{opts: opts} do
    {:ok, spec} = Role.build("worker", "launchd", opts)
    :ok = Unit.write(spec, "launchd")

    output =
      capture_io(fn ->
        assert ServiceCommand.run(["status", "worker", "--name", "studio"], opts) == 0
      end)

    assert output =~ "persistence: login"
    assert output =~ "worker (studio): online"
  end

  test "help and top-level dispatch do not invoke a manager" do
    for argv <- [["--help"], ["-h"], ["help"]] do
      assert capture_io(fn -> assert ServiceCommand.run(argv) == 0 end) =~ "service"
    end

    assert capture_io(fn -> assert CLI.run(["service", "--help"]) == 0 end) =~ "ROLE"
  end
end
