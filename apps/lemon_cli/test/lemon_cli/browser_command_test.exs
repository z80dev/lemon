defmodule LemonCli.BrowserCommandTestClient do
  def request(method, params, opts) do
    send(self(), {:browser_request, method, params, opts})
    Process.get(:browser_response)
  end
end

defmodule LemonCli.BrowserCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.{CLI, CommandRegistry}

  setup do
    previous = Application.get_env(:lemon_cli, :control_plane_client)
    Application.put_env(:lemon_cli, :control_plane_client, LemonCli.BrowserCommandTestClient)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_cli, :control_plane_client, previous),
        else: Application.delete_env(:lemon_cli, :control_plane_client)
    end)

    :ok
  end

  test "browser stop calls browser.stop and reports success" do
    Process.put(:browser_response, {:ok, %{"stopped" => true}})
    assert capture_io(fn -> assert CLI.run(["browser", "stop"]) == 0 end) =~ "stopped"
    assert_received {:browser_request, "browser.stop", %{}, [timeout_ms: 30_000]}

    assert capture_io(fn -> assert CLI.run(["browser", "stop", "--json"]) == 0 end)
           |> Jason.decode!() == %{"stopped" => true}
  end

  test "browser stop fails closed when the runtime is down or does not confirm" do
    Process.put(:browser_response, {:error, {:control_plane_unavailable, :econnrefused}})

    assert capture_io(:stderr, fn -> assert CLI.run(["browser", "stop"]) == 1 end) =~
             "Runtime not running"

    Process.put(:browser_response, {:error, :control_plane_timeout})

    error =
      capture_io(:stderr, fn -> assert CLI.run(["browser", "stop", "--json"]) == 1 end)
      |> Jason.decode!()

    assert error["error"]["kind"] == "stop_timeout"
  end

  test "usage errors exit 2 and help documents the command" do
    assert capture_io(:stderr, fn -> assert CLI.run(["browser"]) == 2 end) =~
             "lemon browser stop"

    refute_received {:browser_request, _, _, _}
    assert CommandRegistry.help("browser") =~ "lemon browser stop [--json]"
  end
end
