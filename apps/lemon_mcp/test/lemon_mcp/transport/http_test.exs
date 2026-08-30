defmodule LemonMCP.Transport.HTTPTest do
  use ExUnit.Case, async: false

  alias LemonMCP.Server
  alias LemonMCP.Transport.HTTP
  alias LemonMCP.Transport.HTTP.RegistryMember
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

  test "instance lookup keeps older transports reachable after the latest stops", %{
    transport: first
  } do
    second_spec = Supervisor.child_spec({HTTP, port: 0, tools: []}, id: :second_http_transport)
    second = start_supervised!(second_spec)
    first_server = TransportSupervisor.server_pid(first)
    second_server = TransportSupervisor.server_pid(second)

    assert HTTP.get_server_pid(first) == first_server
    assert HTTP.get_server_pid(second) == second_server
    assert HTTP.get_server_pid() == second_server

    assert :ok = stop_supervised(:second_http_transport)
    assert HTTP.get_server_pid(second) == nil
    assert HTTP.get_server_pid() == first_server
  end

  test "registry membership recovers with its transport supervisor", %{transport: transport} do
    old_member = TransportSupervisor.registry_member_pid(transport)
    member_ref = Process.monitor(old_member)

    Process.exit(old_member, :kill)
    assert_receive {:DOWN, ^member_ref, :process, ^old_member, :killed}, 1_000

    new_member = eventually(fn -> TransportSupervisor.registry_member_pid(transport) end)
    assert is_pid(new_member)
    assert new_member != old_member
    assert RegistryMember.supervisors() |> Enum.count(&(&1 == transport)) == 1
    assert HTTP.get_server_pid() == HTTP.get_server_pid(transport)
  end

  test "registry retains every concurrent transport and removes stopped members", %{
    transport: original
  } do
    parent = self()

    starters =
      for _index <- 1..12 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :start ->
              result = HTTP.start_link(port: 0, tools: [])
              send(parent, {:started, self(), result})

              receive do
                :release -> :ok
              end
          end
        end)
      end

    starter_pids =
      for _index <- 1..12 do
        assert_receive {:ready, starter}, 1_000
        starter
      end

    Enum.each(starter_pids, &send(&1, :start))

    transports =
      for _index <- 1..12 do
        assert_receive {:started, _starter, {:ok, transport}}, 5_000
        transport
      end

    on_exit(fn ->
      Enum.each(transports, fn transport ->
        if Process.alive?(transport), do: Supervisor.stop(transport)
      end)

      Enum.each(starters, &send(&1.pid, :release))
    end)

    registered = RegistryMember.supervisors()
    assert Enum.all?([original | transports], &(&1 in registered))
    assert length(Enum.uniq(registered)) == length(registered)
    assert HTTP.get_server_pid() == registered |> List.first() |> HTTP.get_server_pid()

    Enum.each(transports, &Supervisor.stop/1)
    Enum.each(starters, &send(&1.pid, :release))
    Enum.each(starters, &Task.await(&1, 1_000))

    assert eventually(fn -> RegistryMember.supervisors() == [original] end)
    assert HTTP.get_server_pid() == HTTP.get_server_pid(original)
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      value when value in [nil, false] ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
