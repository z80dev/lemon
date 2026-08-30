defmodule LemonControlPlane.Methods.BrowserControllerMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize

  alias LemonControlPlane.Methods.{
    BrowserControllerHeartbeat,
    BrowserControllerRegister,
    BrowserControllerResult,
    BrowserControllerStatus,
    BrowserControllerTicket
  }

  test "authenticated ticket to WebSocket result works end to end" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    controller_id = "controller-#{suffix}"
    session_id = "session-#{suffix}"
    run_id = "run-#{suffix}"

    auth = %{Authorize.default_operator() | token: "server-authenticated-token-#{suffix}"}
    operator_ctx = %{auth: auth, conn_pid: self(), conn_id: "operator-#{suffix}"}

    assert {:ok, issued} =
             BrowserControllerTicket.handle(
               %{
                 "controllerId" => controller_id,
                 "browserProfileId" => "chrome-default",
                 "sessionId" => session_id,
                 "runId" => run_id,
                 "capabilities" => ["tabs", "inspect", "evaluate", "root"]
               },
               operator_ctx
             )

    assert issued["singleUse"] == true
    assert issued["capabilities"] == ["evaluate", "inspect", "tabs"]

    controller_ctx = %{auth: Authorize.node_context(controller_id), conn_pid: self()}

    assert {:ok, registered} =
             BrowserControllerRegister.handle(
               %{"ticket" => issued["ticket"], "metadata" => %{"browser" => "Chrome"}},
               controller_ctx
             )

    assert registered["controllerId"] == controller_id
    assert registered["sessionId"] == session_id

    assert {:ok, %{"alive" => true}} =
             BrowserControllerHeartbeat.handle(
               %{"controllerId" => controller_id},
               controller_ctx
             )

    task =
      Task.async(fn ->
        LemonBrowser.request("browser.tabs", %{}, 500,
          backend: :controller,
          controller_id: controller_id,
          browser_profile_id: "chrome-default",
          session_id: session_id,
          run_id: run_id
        )
      end)

    assert_receive {:browser_controller_command, command}, 1_000
    assert command["method"] == "browser.tabs"

    assert {:ok, %{"received" => true}} =
             BrowserControllerResult.handle(
               %{
                 "controllerId" => controller_id,
                 "requestId" => command["requestId"],
                 "result" => %{"tabs" => []}
               },
               controller_ctx
             )

    assert Task.await(task) == {:ok, %{"tabs" => []}}

    assert {:ok, status} = BrowserControllerStatus.handle(%{}, operator_ctx)
    assert Enum.any?(status["controllers"], &(&1["controllerId"] == controller_id))
    refute inspect(status) =~ issued["ticket"]
    refute inspect(status) =~ auth.token
  end

  test "ticket issuance rejects a declared operator without authenticated token" do
    ctx = %{auth: Authorize.default_operator()}

    assert {:error, {:forbidden, message}} =
             BrowserControllerTicket.handle(
               %{
                 "controllerId" => "controller",
                 "browserProfileId" => "profile",
                 "sessionId" => "session"
               },
               ctx
             )

    assert message =~ "authenticated control-plane token"
  end

  test "WebSocket connection converts broker commands to controller events" do
    state = %LemonControlPlane.WS.Connection{
      conn_id: "conn",
      connected: true,
      event_seq: 0,
      state_version: %{},
      subscription_mode: :all,
      subscriptions: MapSet.new()
    }

    assert {:push, {:text, encoded}, next_state} =
             LemonControlPlane.WS.Connection.handle_info(
               {:browser_controller_command, %{"requestId" => "request-1"}},
               state
             )

    decoded = Jason.decode!(encoded)
    assert decoded["event"] == "browser.controller.command"
    assert decoded["payload"]["requestId"] == "request-1"
    assert next_state.event_seq == 1
  end
end
