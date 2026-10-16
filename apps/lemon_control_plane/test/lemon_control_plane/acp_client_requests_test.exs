defmodule LemonControlPlane.ACP.ClientRequestsTest do
  use ExUnit.Case, async: true
  alias LemonControlPlane.ACP.ClientRequests
  alias LemonCore.ACPClientBridge

  test "requester death withdraws an outstanding client callback" do
    owner = self()
    run = LemonCore.Id.run_id()

    {:ok, bridge} =
      ClientRequests.start_link(run, owner, fn _payload ->
        send(owner, {:waiting, self()})

        receive do
          :never -> {%{}, %{}}
        end
      end)

    requester =
      spawn(fn -> ACPClientBridge.request(run, "session/request_permission", %{}, :infinity) end)

    assert_receive {:waiting, callback}
    monitor = Process.monitor(callback)
    Process.exit(requester, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^callback, :killed}
    GenServer.stop(bridge)
  end

  test "withdrawing a permission cancels its callback without killing its requester" do
    owner = self()
    run = LemonCore.Id.run_id()

    {:ok, bridge} =
      ClientRequests.start_link(run, owner, fn _payload ->
        send(owner, {:waiting, self()})

        receive do
          :never -> {%{}, %{}}
        end
      end)

    {requester, requester_monitor} =
      spawn_monitor(fn ->
        response = ACPClientBridge.request(run, "session/request_permission", %{}, :infinity)
        send(owner, {:permission_response, response})
      end)

    assert_receive {:waiting, callback}
    callback_monitor = Process.monitor(callback)
    ClientRequests.cancel_request(run, requester)

    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :killed}
    assert_receive {:permission_response, {:ok, %{"error" => %{"code" => -32_000}}}}
    assert_receive {:DOWN, ^requester_monitor, :process, ^requester, :normal}
    GenServer.stop(bridge)
  end

  test "cancellation before registration rejects the request without starting a callback" do
    owner = self()
    run = LemonCore.Id.run_id()

    {:ok, bridge} =
      ClientRequests.start_link(run, owner, fn _payload ->
        send(owner, :unexpected_callback)
        {%{}, %{}}
      end)

    {requester, monitor} =
      spawn_monitor(fn ->
        receive do
          :register ->
            response = ACPClientBridge.request(run, "session/request_permission", %{}, :infinity)
            send(owner, {:permission_response, response})
        end
      end)

    ClientRequests.cancel_request(run, requester)
    state = :sys.get_state(bridge)
    assert Map.has_key?(state.cancelled, requester)
    assert state.pending == %{}

    send(requester, :register)
    assert_receive {:permission_response, {:ok, %{"error" => %{"code" => -32_000}}}}
    assert_receive {:DOWN, ^monitor, :process, ^requester, :normal}

    refute_received :unexpected_callback
    GenServer.stop(bridge)
  end

  test "long exit wait does not serialize independent output requests" do
    owner = self()
    run = LemonCore.Id.run_id()

    {:ok, bridge} =
      ClientRequests.start_link(run, owner, fn payload ->
        if payload.method == "terminal/wait_for_exit" do
          send(owner, {:waiting, self()})

          receive do
            :never -> :ok
          end
        end

        {%{"result" => %{"output" => "live"}}, %{"method" => payload.method}}
      end)

    waiter =
      spawn(fn -> ACPClientBridge.request(run, "terminal/wait_for_exit", %{}, :infinity) end)

    assert_receive {:waiting, _}

    assert {:ok, %{"result" => %{"output" => "live"}}} =
             ACPClientBridge.request(run, "terminal/output", %{}, 500)

    Process.exit(waiter, :kill)
    GenServer.stop(bridge)
  end
end
