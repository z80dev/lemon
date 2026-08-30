defmodule LemonMCP.Transport.HTTPTest do
  use ExUnit.Case, async: false

  alias LemonMCP.Server
  alias LemonMCP.Transport.HTTP
  alias LemonMCP.Transport.HTTP.Supervisor, as: TransportSupervisor

  setup do
    transport = start_supervised!({HTTP, port: 0, tools: []})
    %{transport: transport}
  end

  test "owns the MCP server and Bandit listener under one transport supervisor", %{
    transport: transport
  } do
    server = TransportSupervisor.server_pid(transport)
    bandit = TransportSupervisor.bandit_pid(transport)

    assert is_pid(server)
    assert is_pid(bandit)
    assert Process.alive?(server)
    assert Process.alive?(bandit)
    assert HTTP.get_server_pid() == server
    assert Process.info(transport, :registered_name) == {:registered_name, []}

    assert %{type: :supervisor} = HTTP.child_spec([])

    assert {:links, links} = Process.info(transport, :links)
    assert server in links
    assert bandit in links
  end

  test "restarts the server and listener together without leaking the old children", %{
    transport: transport
  } do
    old_server = TransportSupervisor.server_pid(transport)
    old_bandit = TransportSupervisor.bandit_pid(transport)
    :ok = Server.mark_initialized(old_server)

    server_ref = Process.monitor(old_server)
    bandit_ref = Process.monitor(old_bandit)
    Process.exit(old_server, :kill)

    assert_receive {:DOWN, ^server_ref, :process, ^old_server, :killed}, 1_000
    assert_receive {:DOWN, ^bandit_ref, :process, ^old_bandit, _reason}, 1_000

    new_server = eventually(fn -> TransportSupervisor.server_pid(transport) end)
    new_bandit = eventually(fn -> TransportSupervisor.bandit_pid(transport) end)

    assert is_pid(new_server)
    assert is_pid(new_bandit)
    assert new_server != old_server
    assert new_bandit != old_bandit
    assert Process.alive?(new_server)
    assert Process.alive?(new_bandit)
    refute Server.initialized?(new_server)
    assert HTTP.get_server_pid() == new_server
  end

  test "restarts the server and listener together when Bandit fails", %{transport: transport} do
    old_server = TransportSupervisor.server_pid(transport)
    old_bandit = TransportSupervisor.bandit_pid(transport)
    :ok = Server.mark_initialized(old_server)

    server_ref = Process.monitor(old_server)
    bandit_ref = Process.monitor(old_bandit)
    Process.exit(old_bandit, :kill)

    assert_receive {:DOWN, ^bandit_ref, :process, ^old_bandit, :killed}, 1_000
    assert_receive {:DOWN, ^server_ref, :process, ^old_server, _reason}, 1_000

    new_server = eventually(fn -> TransportSupervisor.server_pid(transport) end)
    new_bandit = eventually(fn -> TransportSupervisor.bandit_pid(transport) end)

    assert is_pid(new_server)
    assert is_pid(new_bandit)
    assert new_server != old_server
    assert new_bandit != old_bandit
    assert Process.alive?(new_server)
    assert Process.alive?(new_bandit)
    refute Server.initialized?(new_server)
    assert HTTP.get_server_pid() == new_server
  end

  test "stops both children when the transport is stopped", %{transport: transport} do
    server = TransportSupervisor.server_pid(transport)
    bandit = TransportSupervisor.bandit_pid(transport)
    server_ref = Process.monitor(server)
    bandit_ref = Process.monitor(bandit)

    assert :ok = stop_supervised(HTTP)
    assert_receive {:DOWN, ^server_ref, :process, ^server, _reason}, 1_000
    assert_receive {:DOWN, ^bandit_ref, :process, ^bandit, _reason}, 1_000
    refute Process.alive?(transport)
    assert HTTP.get_server_pid() == nil
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
