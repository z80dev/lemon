defmodule LemonCli.CommandRegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias LemonCli.{CLI, CommandRegistry, CompletionCommand}

  @runtime_families ~w(setup model gateway doctor config mcp secrets channels providers blueprints profile backup context sessions runs cron logs omp learn update completion migrate node version send media models policy skill usage)
  @lifecycle ~w(tui web start run daemon stop restart status)
  @release_only ~w(remote eval rpc)

  test "help lists exactly the commands the invoking launcher can run" do
    for {launcher, present, absent} <- [
          {:source, @runtime_families ++ @lifecycle, @release_only},
          {:release, @runtime_families ++ @lifecycle ++ @release_only, []}
        ] do
      help = CommandRegistry.overview(launcher)

      for name <- present, do: assert(help =~ ~r/^  #{name} /m, "#{launcher} help lacks #{name}")
      for name <- absent, do: refute(help =~ ~r/^  #{name} /m, "#{launcher} help lists #{name}")
    end
  end

  test "unknown help names report the error before displaying the command list" do
    error =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> IO.write(CommandRegistry.help("nosuchcommand")) end)
        assert output =~ "Usage: lemon <command>"
      end)

    assert error =~ "Unknown command: nosuchcommand"
    assert error =~ "lemon --help"
  end

  test "unknown help dispatch exits with a usage error" do
    capture_io(:stderr, fn ->
      capture_io(fn -> assert CLI.run(["help", "nosuchcommand"]) == 2 end)
    end)
  end

  test "help and completion contain each command exactly once" do
    for launcher <- [:source, :release] do
      names = Enum.map(CommandRegistry.completion_commands(launcher), & &1.name)
      assert length(names) == length(Enum.uniq(names))

      for name <- ["acp", "tern"] do
        assert length(Regex.scan(~r/^  #{name} /m, CommandRegistry.overview(launcher))) == 1
        assert Enum.count(names, &(&1 == name)) == 1
      end
    end
  end

  test "setup help includes accepted flags and the diagnostics alias" do
    help = CommandRegistry.help("setup")
    assert help =~ "--daily-brief HH:MM"
    assert help =~ "--set-default"
    assert help =~ "alias for doctor"
  end

  test "version and path placeholders describe supported syntax" do
    assert CommandRegistry.overview(:source) =~ "use alone"
    assert CommandRegistry.overview(:source) =~ "lemon version --verbose"
    assert CommandRegistry.help("gateway") =~ "[--transport NAME]"
    assert CommandRegistry.help("tern") =~ "--config-dir PATH"
    refute CommandRegistry.help("tern") =~ "--config-path"

    for command <- CommandRegistry.commands(),
        option <- command.options,
        "--cwd" in option.flags do
      assert option.syntax == "--cwd PATH"
    end
  end

  test "source and release completion share families but not release VM tools" do
    source = Enum.map(CommandRegistry.completion_commands(:source), & &1.name)
    release = Enum.map(CommandRegistry.completion_commands(:release), & &1.name)

    for name <- @runtime_families ++ @lifecycle do
      assert name in source
      assert name in release
    end

    for name <- @release_only do
      assert name in release
      refute name in source
    end
  end

  test "generated shell scripts are deterministic and structurally complete" do
    for shell <- ~w(bash zsh fish), launcher <- [:source, :release] do
      first = CompletionCommand.render(shell, launcher)
      assert first == CompletionCommand.render(shell, launcher)
      assert first =~ "sessions"
      assert first =~ "blueprints"
      assert first =~ "learn"
      assert first =~ "activate"
      assert first =~ "completion"
      assert first =~ "prune"
      assert first =~ "rollback"
      assert first =~ "confirm"
      assert first =~ "follow-up"
      refute first =~ "LEMON_SECRETS_MASTER_KEY"
    end
  end

  test "bash and available shell parsers accept generated scripts" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_completion_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Enum.each(~w(bash zsh fish), fn shell ->
      script = CompletionCommand.render(shell, :release)
      path = Path.join(tmp_dir, "lemon.#{shell}")
      File.write!(path, script)

      case System.find_executable(shell) do
        nil ->
          if shell == "bash", do: flunk("bash is required for completion validation")

        executable ->
          {output, status} = System.cmd(executable, ["-n", path], stderr_to_stdout: true)
          assert status == 0, "#{shell} rejected completion script:\n#{output}"
      end
    end)
  end

  test "completion dispatch has stable help and usage exits" do
    output =
      capture_io(fn ->
        assert CLI.run(["completion", "bash"]) == 0
      end)

    assert output =~ "complete -F _lemon_completion"

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["completion", "powershell"]) == 2
      end)

    assert error == "Usage: lemon completion <bash|zsh|fish>\n"
  end
end
