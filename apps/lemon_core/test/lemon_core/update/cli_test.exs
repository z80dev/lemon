defmodule LemonCore.Update.CLITest do
  use ExUnit.Case, async: false

  alias LemonCore.Update.CLI

  # `--rollback` fails at the layout guard (no valid RELEASE_ROOT under a
  # test's ~/.lemon/versions/) before touching the network at all, which
  # makes it the cheapest deterministic path for exercising argv parsing
  # and the `LEMON_UPDATE_ARGS` fallback without a fixture HTTP server.

  test "run/1 parses --rollback and fails the layout guard offline" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert CLI.run(["--rollback"]) == 1
      end)

    assert output =~ "unsupported_layout"
  end

  test "run/1 falls back to LEMON_UPDATE_ARGS when argv is empty" do
    System.put_env("LEMON_UPDATE_ARGS", "--rollback")
    on_exit(fn -> System.delete_env("LEMON_UPDATE_ARGS") end)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert CLI.run([]) == 1
      end)

    assert output =~ "unsupported_layout"
  end

  test "explicit argv takes priority over LEMON_UPDATE_ARGS" do
    System.put_env("LEMON_UPDATE_ARGS", "--check")
    on_exit(fn -> System.delete_env("LEMON_UPDATE_ARGS") end)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert CLI.run(["--rollback"]) == 1
      end)

    assert output =~ "unsupported_layout"
  end

  test "run/1 emits a JSON error object with --json" do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert CLI.run(["--rollback", "--json"]) == 1
      end)

    assert {:ok, decoded} = Jason.decode(String.trim(stderr))
    assert decoded["error"] =~ "unsupported_layout"
  end
end
