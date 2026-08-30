defmodule LemonCli.UpdateCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  setup do
    previous = System.get_env("LEMON_CLI_LAUNCHER")
    System.put_env("LEMON_CLI_LAUNCHER", "source")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_CLI_LAUNCHER", previous),
        else: System.delete_env("LEMON_CLI_LAUNCHER")
    end)

    :ok
  end

  test "registry help describes the exact-confirmation lifecycle" do
    output = capture_io(fn -> assert CLI.run(["update", "--help"]) == 0 end)

    assert output =~ "lemon update <check|plan|apply|history|rollback>"
    assert output =~ "--confirm DIGEST"
    assert output =~ "--receipt ID"
    assert output =~ "Planning is non-mutating"
  end

  test "source checkout refuses packaged plan, apply, and rollback before mutation" do
    for command <- ~w(plan apply rollback) do
      error =
        capture_io(:stderr, fn ->
          assert CLI.run(["update", command]) == 1
        end)

      assert error =~ "Source checkouts cannot plan, apply, or roll back release artifacts"
      assert error =~ "reviewed git pull workflow"
    end
  end

  test "invalid combinations return a stable usage exit" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["update", "plan", "apply"]) == 2
      end)

    assert error =~ "Usage: lemon update"
  end
end
