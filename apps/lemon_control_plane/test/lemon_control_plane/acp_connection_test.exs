defmodule LemonControlPlane.ACP.ConnectionTest do
  use ExUnit.Case, async: false
  import Plug.Test, except: [conn: 2, conn: 3]
  import Plug.Conn

  alias LemonControlPlane.ACP.Connection
  alias LemonControlPlane.HTTP.Router

  test "malformed JSON produces a protocol error without killing the connection" do
    {:ok, state} = Connection.init([])

    assert {:push, {:text, encoded}, ^state} =
             Connection.handle_in({"{broken", [opcode: :text]}, state)

    assert Jason.decode!(encoded) == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{"code" => -32_700, "message" => "parse error"}
           }

    assert {:ok, ^state} =
             Connection.handle_in(
               {~s({"jsonrpc":"2.0","id":"unknown","result":{}}), [opcode: :text]},
               state
             )
  end

  test "session/cancel releases a pending permission callback" do
    {:ok, state} = Connection.init([])
    ref = make_ref()
    request = %{"method" => "session/request_permission", "params" => %{}}

    {:push, {:text, wire}, state} =
      Connection.handle_info(
        {:acp_client_request, self(), ref, request, "session", self()},
        state
      )

    request_id = Jason.decode!(wire)["id"]

    request = ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"session"}})
    assert {:ok, state} = Connection.handle_in({request, [opcode: :text]}, state)
    assert state.clients == %{}
    assert_receive {:acp_client_response, ^ref, {:error, :cancelled}}

    assert_receive {:acp_output,
                    %{
                      "method" => "$/cancel_request",
                      "params" => %{"requestId" => ^request_id}
                    }}

    Connection.terminate(:normal, state)
  end

  test "late terminal allocation after cancellation is killed and released" do
    {:ok, state} = Connection.init([])
    ref = make_ref()
    request = %{"method" => "terminal/create", "params" => %{}}

    {:push, {:text, wire}, state} =
      Connection.handle_info(
        {:acp_client_request, self(), ref, request, "session", self()},
        state
      )

    id = Jason.decode!(wire)["id"]
    cancel = ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"session"}})
    {:ok, state} = Connection.handle_in({cancel, [opcode: :text]}, state)
    assert_receive {:acp_client_response, ^ref, {:error, :cancelled}}

    response =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"terminalId" => "late"}})

    {:ok, state} = Connection.handle_in({response, [opcode: :text]}, state)
    assert state.clients == %{}
    assert state.terminals == %{}

    assert_receive {:acp_output,
                    %{"method" => "terminal/kill", "params" => %{"terminalId" => "late"}}}

    assert_receive {:acp_output,
                    %{"method" => "terminal/release", "params" => %{"terminalId" => "late"}}}

    Connection.terminate(:normal, state)
  end

  test "terminal output can complete while wait_for_exit remains pending" do
    {:ok, state} = Connection.init([])
    wait_ref = make_ref()
    output_ref = make_ref()
    wait = %{"method" => "terminal/wait_for_exit", "params" => %{"terminalId" => "t"}}
    output = %{"method" => "terminal/output", "params" => %{"terminalId" => "t"}}

    {:push, _, state} =
      Connection.handle_info(
        {:acp_client_request, self(), wait_ref, wait, "session", self()},
        state
      )

    {:push, {:text, wire}, state} =
      Connection.handle_info(
        {:acp_client_request, self(), output_ref, output, "session", self()},
        state
      )

    response = %{
      "jsonrpc" => "2.0",
      "id" => Jason.decode!(wire)["id"],
      "result" => %{"output" => "live"}
    }

    {:ok, state} = Connection.handle_in({Jason.encode!(response), [opcode: :text]}, state)
    assert_receive {:acp_client_response, ^output_ref, {:ok, ^response}}
    refute_receive {:acp_client_response, ^wait_ref, _}
    assert map_size(state.clients) == 1
    Connection.terminate(:normal, state)
  end

  test "duplex transport is not exposed by the optional unauthenticated HTTP ACP endpoint" do
    previous = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    Application.put_env(:lemon_control_plane, :operator_token, "transport-test-token")
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    on_exit(fn ->
      restore(:operator_token, previous)
      restore(:allow_unauthenticated_loopback_operator, previous_loopback)
    end)

    response = conn(:get, "/acp/ws") |> Router.call(Router.init([]))
    assert response.status == 401

    response =
      conn(:get, "/acp/ws")
      |> put_req_header("authorization", "Bearer invalid")
      |> Router.call(Router.init([]))

    assert response.status == 401
  end

  defp restore(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore(key, value), do: Application.put_env(:lemon_control_plane, key, value)

  # The router refuses non-loopback Host headers from loopback peers.
  defp conn(method, path, body \\ nil),
    do: %{Plug.Test.conn(method, path, body) | host: "localhost"}
end
