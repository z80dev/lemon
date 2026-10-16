defmodule LemonCli.ConnectCommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias LemonCli.{CLI, ConnectCommand}

  @args ["iphone", "--backend", "http://127.0.0.1:8787", "--origin", "https://bot.example.ts.net"]

  setup do
    root = Path.join(System.tmp_dir!(), "lemon_connect_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, absent: Path.join(root, "absent.ts")}
  end

  test "dispatch preserves usage failure and never echoes rejected values" do
    for args <- [
          [],
          ["iphone"],
          ["android", "private-value"],
          @args ++ ["--token", "private-value"],
          @args ++ ["--approve"],
          @args ++ ["--backend", "private-value"],
          ["iphone", "--backend", "--secret"]
        ] do
      error = capture_io(:stderr, fn -> assert CLI.run(["connect" | args]) == 2 end)
      assert error =~ "Usage: lemon connect iphone"
      refute error =~ "private-value"
      refute error =~ "--secret"
    end
  end

  test "command help does not launch or authenticate" do
    output = capture_io(fn -> assert CLI.run(["connect", "iphone", "--help"]) == 0 end)
    assert output =~ "--backend ORIGIN"
    assert output =~ "--origin HTTPS_ORIGIN"
  end

  test "source uses an absolute script with inherited terminal and exact exit", %{root: root} do
    script = Path.join(root, "connect.ts")
    File.write!(script, "source fixture")

    assert ConnectCommand.run(@args,
             source_script: script,
             find_executable: fn "bun" -> "/runtime/bun" end,
             open_port: port_probe("/runtime/bun", [script | @args], 37)
           ) == 37

    assert_received :terminal_opened
  end

  test "installed Bot layout precedes PATH and requires no Bun", %{root: root, absent: absent} do
    installed = Path.join(root, ".lemon/lemon_bot/current/bot/bin/lemon-bot")

    assert ConnectCommand.run(@args,
             source_script: absent,
             home: root,
             find_executable: fn ^installed -> installed end,
             open_port: port_probe(installed, ["connect" | @args], 0)
           ) == 0
  end

  test "release falls back to executable PATH", %{root: root, absent: absent} do
    assert ConnectCommand.run(@args,
             source_script: absent,
             home: root,
             find_executable: fn
               "lemon-bot" -> "/installed/lemon-bot"
               _path -> nil
             end,
             open_port: port_probe("/installed/lemon-bot", ["connect" | @args], 2)
           ) == 2
  end

  test "missing source runtime is actionable without falling back", %{root: root} do
    script = Path.join(root, "connect.ts")
    File.write!(script, "source fixture")

    error =
      capture_io(:stderr, fn ->
        assert ConnectCommand.run(@args,
                 source_script: script,
                 find_executable: fn "bun" -> nil end
               ) == 1
      end)

    assert error =~ "Install Bun"
  end

  test "missing standalone executable is actionable", %{root: root, absent: absent} do
    error =
      capture_io(:stderr, fn ->
        assert ConnectCommand.run(@args,
                 source_script: absent,
                 home: root,
                 find_executable: fn _path -> nil end
               ) == 1
      end)

    assert error =~ "standalone Lemon Bot"
    assert error =~ "Start/configure its backend separately"
  end

  test "spawn failures are redacted", %{root: root, absent: absent} do
    error =
      capture_io(:stderr, fn ->
        assert ConnectCommand.run(@args,
                 source_script: absent,
                 home: root,
                 find_executable: fn _path -> "/installed/lemon-bot" end,
                 open_port: fn _command, _opts -> raise ArgumentError, "private-value" end
               ) == 1
      end)

    assert error =~ "Could not execute the pairing client"
    refute error =~ "private-value"
  end

  defp port_probe(executable, args, status) do
    fn command, opts ->
      assert command == {:spawn_executable, String.to_charlist(executable)}
      assert :nouse_stdio in opts
      assert :exit_status in opts
      refute :use_stdio in opts
      refute :stderr_to_stdout in opts
      refute Keyword.has_key?(opts, :cd)
      assert Keyword.fetch!(opts, :args) == Enum.map(args, &String.to_charlist/1)
      port = make_ref()
      send(self(), :terminal_opened)
      send(self(), {port, {:exit_status, status}})
      port
    end
  end
end
