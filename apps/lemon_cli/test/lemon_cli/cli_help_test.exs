defmodule LemonCli.CLIHelpTest do
  @moduledoc """
  Focus: `--help` must print command-specific usage on stdout, return 0, and
  never execute the command body — no wizard run, no provider onboarding, no
  gateway dispatch, no config/secrets mutation.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  # {argv, expected usage substring, sentinel that proves the command body ran}
  @help_cases [
    {["setup", "--help"], "Usage: lemon setup", "Welcome to Lemon setup!"},
    {["model", "--help"], "Usage: lemon model", "Lemon Provider Onboarding"},
    {["gateway", "setup", "--help"], "Usage: lemon gateway setup",
     "Available gateway transports:"},
    {["gateway", "--help"], "Usage: lemon gateway setup", "Available gateway transports:"},
    {["doctor", "--help"], "Usage: lemon doctor", "Lemon Doctor"},
    {["config", "--help"], "Usage: lemon config", "Validating Lemon configuration"},
    {["secrets", "--help"], "Usage: lemon secrets", "No secrets configured"},
    {["channels", "--help"], "Usage: lemon channels", "Lemon Channels"},
    {["backup", "--help"], "Usage: lemon backup", "Backup created"},
    {["context", "--help"], "Usage: lemon context", "Context preview:"}
  ]

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_cli_help_#{System.unique_integer([:positive])}")

    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    original_home = System.get_env("HOME")
    System.put_env("HOME", mock_home)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, lemon_home: Path.join(mock_home, ".lemon")}
  end

  test "--help prints command usage, returns 0, and leaves state untouched",
       %{lemon_home: lemon_home} do
    for {argv, usage_pattern, body_sentinel} <- @help_cases do
      output =
        capture_io(fn ->
          send(self(), {:exit_code, CLI.run(argv)})
        end)

      assert output =~ usage_pattern,
             "expected #{inspect(usage_pattern)} in output for #{inspect(argv)}"

      refute output =~ body_sentinel,
             "command body executed for #{inspect(argv)} (saw #{inspect(body_sentinel)})"

      assert_received {:exit_code, 0}

      refute File.exists?(lemon_home),
             "help mutated Lemon state under #{lemon_home} for #{inspect(argv)}"
    end
  end

  test "-h and trailing positionals still route to help without executing" do
    for argv <- [["setup", "-h"], ["secrets", "set", "--help"], ["setup", "--help", "provider"]] do
      output =
        capture_io(fn ->
          send(self(), {:exit_code, CLI.run(argv)})
        end)

      assert output =~ "Usage: lemon"
      assert_received {:exit_code, 0}
    end
  end
end
