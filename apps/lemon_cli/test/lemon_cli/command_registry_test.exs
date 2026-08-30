defmodule LemonCli.CommandRegistryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias LemonCli.{CLI, CommandRegistry, CompletionCommand}

  @runtime_families ~w(setup model gateway doctor config secrets channels providers blueprints profile backup context sessions learn update completion)

  test "registry is the complete unique runtime family source for dispatch and help" do
    assert CommandRegistry.names() == @runtime_families
    assert length(Enum.uniq(CommandRegistry.names())) == length(@runtime_families)

    Enum.each(CommandRegistry.commands(), fn command ->
      assert is_binary(command.summary) and command.summary != ""
      assert is_binary(command.usage) and String.starts_with?(command.usage, "lemon ")
      assert is_list(command.subcommands)
      assert is_list(command.options)
      assert CommandRegistry.help(command.name) =~ "Usage: #{command.usage}"
    end)

    help = CommandRegistry.help()
    Enum.each(@runtime_families, &assert(help =~ &1))
  end

  test "source and release completion metadata preserve their own launcher commands" do
    source = Enum.map(CommandRegistry.completion_commands(:source), & &1.name)
    release = Enum.map(CommandRegistry.completion_commands(:release), & &1.name)

    assert "send" in source
    assert "node" in source
    refute "tui" in source
    refute "daemon" in source

    assert "tui" in release
    assert "daemon" in release
    refute "send" in release
    refute "node" in release

    Enum.each(@runtime_families, fn family ->
      assert family in source
      assert family in release
    end)
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
