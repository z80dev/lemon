defmodule LemonCli.ReloadCommandTestClient do
  def request(method, params, opts) do
    send(self(), {:reload_request, method, params, opts})
    Process.get(:reload_response)
  end
end

defmodule LemonCli.ReloadCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.{CLI, CommandRegistry, CompletionCommand}

  setup do
    previous_client = Application.get_env(:lemon_cli, :control_plane_client)
    previous_launcher = System.get_env("LEMON_CLI_LAUNCHER")
    Application.put_env(:lemon_cli, :control_plane_client, LemonCli.ReloadCommandTestClient)
    System.put_env("LEMON_CLI_LAUNCHER", "source")

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:lemon_cli, :control_plane_client, previous_client),
        else: Application.delete_env(:lemon_cli, :control_plane_client)

      if previous_launcher,
        do: System.put_env("LEMON_CLI_LAUNCHER", previous_launcher),
        else: System.delete_env("LEMON_CLI_LAUNCHER")
    end)

    :ok
  end

  defp result do
    %{
      "reloaded" => ["Example.Changed"],
      "inUse" => ["Example.Busy"],
      "failed" => [%{"module" => "Example.Failed", "reason" => "badfile"}],
      "reloadedCount" => 1,
      "inUseCount" => 1,
      "failedCount" => 1,
      "sessions" => %{"refreshed" => 2, "busy" => 3, "failed" => 1}
    }
  end

  test "reload reports partial results and refreshes sessions by default" do
    Process.put(:reload_response, {:ok, result()})
    output = capture_io(fn -> assert CLI.run(["reload"]) == 0 end)
    assert output =~ "Code: 1 reloaded, 1 in use, 1 failed."
    assert output =~ "Sessions: 2 refreshed, 3 busy, 1 failed."
    assert output =~ "Example.Failed (badfile)"
    assert output =~ "Example.Busy. Restart required."

    assert_received {:reload_request, "system.reload_code", %{"sessions" => true},
                     [timeout_ms: 60_000]}
  end

  test "JSON preserves results and no-sessions disables refreshing" do
    payload = %{result() | "sessions" => %{"refreshed" => 0, "busy" => 0, "failed" => 0}}
    Process.put(:reload_response, {:ok, payload})
    output = capture_io(fn -> assert CLI.run(~w(reload --no-sessions --json)) == 0 end)
    assert Jason.decode!(output) == payload

    assert_received {:reload_request, "system.reload_code", %{"sessions" => false},
                     [timeout_ms: 60_000]}
  end

  test "a no-op succeeds without restart guidance" do
    payload = %{
      "reloaded" => [],
      "inUse" => [],
      "failed" => [],
      "reloadedCount" => 0,
      "inUseCount" => 0,
      "failedCount" => 0,
      "sessions" => %{"refreshed" => 0, "busy" => 0, "failed" => 0}
    }

    Process.put(:reload_response, {:ok, payload})
    output = capture_io(fn -> assert CLI.run(["reload"]) == 0 end)
    assert output =~ "0 reloaded, 0 in use, 0 failed"
    refute output =~ "Restart required"
  end

  test "unavailable runtime fails without starting one or exposing transport details" do
    Process.put(:reload_response, {:error, {:control_plane_unavailable, "private-detail"}})
    output = capture_io(:stderr, fn -> assert CLI.run(["reload"]) == 1 end)
    assert output =~ "Runtime not running"
    assert output =~ "lemon daemon"
    refute output =~ "private-detail"
    assert_received {:reload_request, "system.reload_code", _, _}
    refute_received {:reload_request, _, _, _}
  end

  test "RPC refusal and timeout emit safe JSON errors" do
    for {reason, kind} <- [
          {{:control_plane, %{"message" => "private-detail"}}, "reload_refused"},
          {:control_plane_timeout, "reload_timeout"},
          {:disconnected, "reload_unavailable"}
        ] do
      Process.put(:reload_response, {:error, reason})
      output = capture_io(:stderr, fn -> assert CLI.run(~w(reload --json)) == 1 end)
      assert Jason.decode!(output)["error"]["kind"] == kind
      refute output =~ "private-detail"
    end
  end

  test "invalid usage and help do not contact the runtime" do
    for args <- [~w(reload extra), ~w(reload --unknown), ~w(reload --sessions=invalid)] do
      output = capture_io(:stderr, fn -> assert CLI.run(args) == 2 end)
      assert output =~ "Usage: lemon reload"
    end

    assert capture_io(fn -> assert CLI.run(~w(reload --help)) == 0 end) =~ "--no-sessions"
    refute_received {:reload_request, _, _, _}
  end

  test "release dispatch refuses reload, including help" do
    System.put_env("LEMON_CLI_LAUNCHER", "release")

    for args <- [["reload"], ~w(reload --help)] do
      output = capture_io(:stderr, fn -> assert CLI.run(args) == 2 end)
      assert output =~ "available only from a source checkout"
    end

    refute_received {:reload_request, _, _, _}
  end

  test "registry availability, help and completions are source-only" do
    assert {:ok, entry} = CommandRegistry.fetch("reload")
    assert entry.launchers == [:source]
    assert CommandRegistry.available?(entry, :source)
    refute CommandRegistry.available?(entry, :release)
    refute CommandRegistry.lifecycle?("reload")
    assert CommandRegistry.overview(:source) =~ ~r/^  reload /m
    refute CommandRegistry.overview(:release) =~ ~r/^  reload /m

    help = CommandRegistry.help("reload")
    assert help =~ "lemon reload [--no-sessions] [--json]"
    assert help =~ "never starts a runtime"
    assert help =~ "state shapes require a restart"

    for shell <- ~w(bash zsh fish) do
      source = CompletionCommand.render(shell, :source)
      release = CompletionCommand.render(shell, :release)
      assert source =~ "reload"
      assert source =~ if(shell == "fish", do: "-l 'no-sessions'", else: "--no-sessions")
      refute release =~ "reload"
    end
  end
end
