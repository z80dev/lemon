defmodule LemonBrowser.ControllerBrokerTest do
  use ExUnit.Case, async: true

  alias LemonBrowser.ControllerBroker

  setup do
    name = Module.concat(__MODULE__, "Broker#{System.unique_integer([:positive])}")
    start_supervised!({ControllerBroker, name: name, ticket_ttl_ms: 50, heartbeat_ttl_ms: 50})
    %{server: name}
  end

  test "ticket is single-use and capabilities are filtered", %{server: server} do
    attrs = identity(capabilities: ["tabs", "evaluate", "root", "cookies"])
    assert {:ok, issued} = ControllerBroker.issue_ticket(attrs, server: server)
    assert issued.capabilities == ["cookies", "evaluate", "tabs"]

    assert {:ok, controller} =
             ControllerBroker.register(issued.ticket, self(), %{"name" => "Chrome"},
               server: server
             )

    assert controller.controller_id == "controller-1"
    assert controller.principal_id == "principal-from-server"
    assert controller.metadata == %{"name" => "Chrome"}

    assert {:error, :invalid_or_consumed_ticket} =
             ControllerBroker.register(issued.ticket, self(), %{}, server: server)
  end

  test "expired tickets fail closed", %{server: server} do
    assert {:ok, issued} = ControllerBroker.issue_ticket(identity(), server: server, ttl_ms: 1)
    Process.sleep(5)

    assert {:error, :expired_ticket} =
             ControllerBroker.register(issued.ticket, self(), %{}, server: server)
  end

  test "commands require an exact controller binding and capability", %{server: server} do
    register_controller(server, self(), capabilities: ["tabs"])

    task =
      Task.async(fn ->
        ControllerBroker.request(
          %{controller_id: "controller-1", session_id: "session-1", run_id: "run-1"},
          "browser.tabs",
          %{},
          500,
          server: server
        )
      end)

    assert_receive {:browser_controller_command, command}
    assert command["method"] == "browser.tabs"
    assert command["capability"] == "tabs"
    assert command["sessionId"] == "session-1"

    assert :ok =
             ControllerBroker.complete(
               "controller-1",
               self(),
               command["requestId"],
               {:ok, %{"tabs" => []}},
               server: server
             )

    assert Task.await(task) == {:ok, %{"tabs" => []}}

    assert {:error, :browser_controller_not_found} =
             ControllerBroker.request(
               %{controller_id: "controller-1", session_id: "different"},
               "browser.tabs",
               %{},
               50,
               server: server
             )

    assert {:error, {:browser_capability_denied, "evaluate"}} =
             ControllerBroker.request(
               %{controller_id: "controller-1"},
               "browser.evaluate",
               %{},
               50,
               server: server
             )
  end

  test "a different process cannot spoof a result or heartbeat", %{server: server} do
    register_controller(server, self(), capabilities: ["tabs"])

    task =
      Task.async(fn ->
        ControllerBroker.request(
          %{controller_id: "controller-1"},
          "browser.tabs",
          %{},
          500,
          server: server
        )
      end)

    assert_receive {:browser_controller_command, command}
    impostor = spawn(fn -> Process.sleep(:infinity) end)

    assert {:error, :controller_identity_mismatch} =
             ControllerBroker.complete(
               "controller-1",
               impostor,
               command["requestId"],
               {:ok, :spoofed},
               server: server
             )

    assert {:error, :controller_identity_mismatch} =
             ControllerBroker.heartbeat("controller-1", impostor, server: server)

    assert :ok =
             ControllerBroker.complete(
               "controller-1",
               self(),
               command["requestId"],
               {:ok, :real},
               server: server
             )

    assert Task.await(task) == {:ok, :real}
    Process.exit(impostor, :kill)
  end

  test "timeout and controller death resolve pending callers", %{server: server} do
    controller = spawn(fn -> receive do: (:stop -> :ok) end)
    register_controller(server, controller, capabilities: ["tabs"])

    assert {:error, :browser_controller_timeout} =
             ControllerBroker.request(
               %{controller_id: "controller-1"},
               "browser.tabs",
               %{},
               5,
               server: server
             )

    task =
      Task.async(fn ->
        ControllerBroker.request(
          %{controller_id: "controller-1"},
          "browser.tabs",
          %{},
          500,
          server: server
        )
      end)

    Process.sleep(5)
    send(controller, :stop)
    assert Task.await(task) == {:error, :controller_disconnected}
    assert ControllerBroker.status(server: server).controller_count == 0
  end

  test "timeouts notify the controller and stale heartbeats fail closed", %{server: server} do
    register_controller(server, self(), capabilities: ["tabs"])

    task =
      Task.async(fn ->
        ControllerBroker.request(
          %{controller_id: "controller-1"},
          "browser.tabs",
          %{},
          5,
          server: server
        )
      end)

    assert_receive {:browser_controller_command, command}

    assert_receive {:browser_controller_cancel,
                    %{"requestId" => request_id, "reason" => "timeout"}}

    assert request_id == command["requestId"]
    assert Task.await(task) == {:error, :browser_controller_timeout}

    Process.sleep(55)

    assert {:error, :browser_controller_not_found} =
             ControllerBroker.request(
               %{controller_id: "controller-1"},
               "browser.tabs",
               %{},
               5,
               server: server
             )

    assert ControllerBroker.status(server: server).controller_count == 0
  end

  defp register_controller(server, pid, overrides) do
    attrs = identity(overrides)
    {:ok, issued} = ControllerBroker.issue_ticket(attrs, server: server)
    ControllerBroker.register(issued.ticket, pid, %{}, server: server)
  end

  defp identity(overrides \\ []) do
    %{
      controller_id: "controller-1",
      browser_profile_id: "chrome-default",
      session_id: "session-1",
      run_id: "run-1",
      principal_id: "principal-from-server",
      capabilities: ["tabs", "inspect"]
    }
    |> Map.merge(Map.new(overrides))
  end
end
