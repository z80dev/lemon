defmodule LemonControlPlane.OperatorAuthWireE2ETest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.Socket

  defmodule PeerContextHandler do
    @behaviour LemonControlPlane.Method
    def name, do: "wire.test.peer_context"
    def scopes, do: [:write]

    def handle(_params, ctx) do
      {:ok,
       %{
         "directLoopback" => LemonControlPlane.Auth.Authorize.loopback_address?(ctx[:peer]),
         "tokenless" => ctx[:local?]
       }}
    end
  end

  setup do
    previous_token = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    Application.put_env(:lemon_control_plane, :operator_token, "wire-operator-secret")
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    on_exit(fn ->
      restore_env(:operator_token, previous_token)
      restore_env(:allow_unauthenticated_loopback_operator, previous_loopback)
    end)

    :ok
  end

  test "real loopback WebSocket requires and accepts the connect auth envelope" do
    suffix = System.unique_integer([:positive])

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:operator_auth_wire_bandit, suffix},
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    url = "ws://127.0.0.1:#{port}/ws"

    authenticated =
      start_socket(suffix, :authenticated,
        url: url,
        connect_params: %{
          "role" => "operator",
          "auth" => %{"token" => "wire-operator-secret"},
          "client" => %{"id" => "launcher-auth-wire-test"}
        }
      )

    assert_receive {:execution_node_socket, ^authenticated, {:connected, hello}}, 3_000
    assert get_in(hello, ["auth", "role"]) == "operator"

    assert :ok = LemonControlPlane.Methods.Registry.register(PeerContextHandler)
    on_exit(fn -> LemonControlPlane.Methods.Registry.unregister(PeerContextHandler.name()) end)
    Socket.request(authenticated, PeerContextHandler.name(), %{"peer" => "192.0.2.1"}, :peer)

    assert_receive {:execution_node_socket, ^authenticated,
                    {:response, :peer, {:ok, %{"directLoopback" => true, "tokenless" => false}}}},
                   3_000

    missing =
      start_socket(suffix, :missing,
        url: url,
        connect_params: %{
          "role" => "operator",
          "client" => %{"id" => "launcher-auth-wire-test-missing"}
        }
      )

    assert_receive {:execution_node_socket, ^missing, {:authentication_error, error}}, 3_000
    assert error["code"] == "UNAUTHORIZED"
    assert error["message"] =~ "Operator token is required"
    assert error["message"] =~ "connect.auth.token"
    assert error["message"] =~ "LEMON_CONTROL_PLANE_OPERATOR_TOKEN"
    refute inspect(error) =~ "wire-operator-secret"
  end

  defp start_socket(suffix, label, opts) do
    start_supervised!(%{
      id: {:operator_auth_wire_socket, suffix, label},
      start:
        {Socket, :start_link,
         [
           [
             owner: self(),
             url: Keyword.fetch!(opts, :url),
             connect_params: Keyword.fetch!(opts, :connect_params),
             reconnect_delay_ms: 10,
             ping_interval_ms: 0
           ]
         ]},
      restart: :temporary
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_control_plane, key, value)
end
