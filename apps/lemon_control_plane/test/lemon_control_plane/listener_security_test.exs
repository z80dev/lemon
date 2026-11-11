defmodule LemonControlPlane.ListenerSecurityTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias LemonControlPlane.{ListenerPolicy, NodeGateway}
  alias LemonControlPlane.HTTP.{NodeRouter, Router}
  alias LemonControlPlane.WS.Connection

  defmodule RemoteRouter do
    def init(opts), do: opts

    def call(conn, opts),
      do: LemonControlPlane.HTTP.Router.call(%{conn | remote_ip: {192, 168, 1, 9}}, opts)
  end

  @keys [
    :ip,
    :operator_token,
    :allow_unauthenticated_loopback_operator,
    :remote_http_apis,
    :openai_compat_api_token,
    :acp_api_token,
    :model_catalog,
    :public_ws_url,
    :node_source_checkout
  ]
  @env [
    "LEMON_CONTROL_PLANE_OPERATOR_TOKEN",
    "LEMON_OPENAI_COMPAT_API_TOKEN",
    "LEMON_OPENAI_COMPAT_TOKEN",
    "LEMON_ACP_API_TOKEN"
  ]

  setup do
    old = Map.new(@keys, &{&1, Application.fetch_env(:lemon_control_plane, &1)})
    old_env = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@keys, &Application.delete_env(:lemon_control_plane, &1))
    Enum.each(@env, &System.delete_env/1)
    Application.put_env(:lemon_control_plane, :model_catalog, fn _ -> [] end)

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:lemon_control_plane, key, value)
          :error -> Application.delete_env(:lemon_control_plane, key)
        end
      end

      for {key, value} <- old_env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "off-loopback main listener only exposes websocket and health by default" do
    for path <- ["/v1/models", "/acp", "/acp/ws", "/missing"] do
      response = remote(:get, path) |> Router.call([])
      assert response.status == 404
      assert Jason.decode!(response.resp_body)["error"]["code"] == "NOT_FOUND"
    end

    assert (remote(:get, "/healthz") |> Router.call([])).status == 200
    assert_websocket_upgrade(RemoteRouter)
  end

  test "remote API opt-in still requires its bearer and is path-segment limited" do
    Application.put_env(:lemon_control_plane, :remote_http_apis, [:openai])
    Application.put_env(:lemon_control_plane, :openai_compat_api_token, "api-secret")
    assert (remote(:get, "/v1/models") |> Router.call([])).status == 401

    assert (remote(:get, "/v1/models")
            |> put_req_header("authorization", "Bearer api-secret")
            |> Router.call([])).status == 200

    assert (remote(:get, "/acp/ws") |> Router.call([])).status == 404
    assert (remote(:get, "/v1-other") |> Router.call([])).status == 404
    # Caller-supplied proxy headers do not turn a remote peer into loopback.
    assert (remote(:get, "/acp")
            |> put_req_header("x-forwarded-for", "127.0.0.1")
            |> Router.call([])).status == 404
  end

  test "local HTTP defaults fail closed and accept the operator token as fallback" do
    for {method, path} <- [{:get, "/v1/models"}, {:post, "/acp"}] do
      denied = conn(method, path) |> Router.call([])
      assert denied.status == 401
      assert denied.resp_body =~ "control-plane-<port>.token"
    end

    Application.put_env(:lemon_control_plane, :operator_token, "operator-secret")

    assert (conn(:get, "/v1/models")
            |> put_req_header("authorization", "Bearer operator-secret")
            |> Router.call([])).status == 200

    Application.delete_env(:lemon_control_plane, :operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)
    assert (conn(:get, "/v1/models") |> Router.call([])).status == 200
    Application.put_env(:lemon_control_plane, :remote_http_apis, [:openai])
    assert (remote(:get, "/v1/models") |> Router.call([])).status == 401
  end

  test "public main and web binds require an operator credential and reject compatibility" do
    Application.put_env(:lemon_control_plane, :ip, {0, 0, 0, 0})
    assert {:error, message} = LemonControlPlane.Application.start(:normal, [])
    assert message =~ "LEMON_CONTROL_PLANE_OPERATOR_TOKEN"
    assert {:error, _} = ListenerPolicy.validate_operator_bind({0, 0, 0, 0}, "LemonWeb")
    Application.put_env(:lemon_control_plane, :operator_token, "operator-secret")
    assert :ok = ListenerPolicy.validate()
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)
    assert {:error, message} = ListenerPolicy.validate()
    assert message =~ "ALLOW_UNAUTHENTICATED_LOOPBACK"
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)
    Application.put_env(:lemon_control_plane, :remote_http_apis, [:openai])
    assert {:error, _} = ListenerPolicy.validate()
    Application.put_env(:lemon_control_plane, :openai_compat_api_token, "api-secret")
    assert :ok = ListenerPolicy.validate()
  end

  test "node gateway exposes only health and websocket" do
    assert conn(:get, "/healthz")
           |> NodeRouter.call([])
           |> Map.fetch!(:resp_body)
           |> Jason.decode!() ==
             %{"ok" => true, "service" => "lemon-node-gateway"}

    for {method, path} <- [{:get, "/"}, {:get, "/v1/models"}, {:post, "/acp"}, {:post, "/ws"}] do
      assert (conn(method, path) |> NodeRouter.call([])).status == 404
    end

    assert_websocket_upgrade(NodeRouter)
  end

  test "node gateway rejects operators and tokenless clients even in compatibility mode" do
    Application.put_env(:lemon_control_plane, :operator_token, "operator-secret")
    assert {:ok, state} = gateway_connection()

    assert {:push, {:text, response}, denied} =
             connect(state, %{"auth" => %{"token" => "operator-secret"}})

    assert Jason.decode!(response)["error"]["code"] == "UNAUTHORIZED"
    refute denied.connected
    Application.delete_env(:lemon_control_plane, :operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)
    assert {:ok, state} = gateway_connection()
    refute state.local?
    assert {:push, {:text, response}, denied} = connect(state, %{})
    assert Jason.decode!(response)["error"]["code"] == "UNAUTHORIZED"
    refute denied.connected
  end

  test "node gateway accepts a valid enrollment invite" do
    Application.put_env(:lemon_control_plane, :public_ws_url, "ws://127.0.0.1:4044/ws")

    Application.put_env(
      :lemon_control_plane,
      :node_source_checkout,
      Path.expand("../../..", __DIR__)
    )

    ctx = %{auth: %{role: :operator, scopes: [:pairing]}, conn_id: "gateway-test"}
    name = "gateway-enrollment-#{System.unique_integer([:positive])}"

    assert {:ok, invite} =
             LemonControlPlane.Methods.NodePairInvite.handle(%{"nodeName" => name}, ctx)

    digest = :crypto.hash(:sha256, invite["inviteCode"]) |> Base.encode16(case: :lower)
    on_exit(fn -> LemonCore.Store.delete(:node_pair_invites, digest) end)
    assert {:ok, state} = gateway_connection()

    assert {:push, {:text, hello}, connected} =
             connect(state, %{
               "role" => "enrollment",
               "auth" => %{"inviteCode" => invite["inviteCode"]}
             })

    assert Jason.decode!(hello)["type"] == "hello-ok"
    assert connected.auth.role == :enrollment
    Connection.terminate(:normal, connected)
  end

  test "occupied or disabled node gateway is nonfatal and unavailable" do
    assert :ignore = NodeGateway.start_link(port: 0)
    refute NodeGateway.status().available
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, {_ip, port}} = :inet.sockname(socket)
    assert :ignore = NodeGateway.start_link(port: port, ip: {127, 0, 0, 1})
    refute NodeGateway.status().available
  end

  test "runtime rejects invalid bind addresses" do
    path = Path.expand("../../../../config/runtime.exs", __DIR__)

    for name <- [
          "LEMON_CONTROL_PLANE_BIND_IP",
          "LEMON_CONTROL_PLANE_NODE_BIND_IP",
          "LEMON_WEB_BIND_IP",
          "LEMON_SIM_UI_BIND_IP"
        ] do
      previous = System.get_env(name)
      System.put_env(name, "invalid-address")

      try do
        assert_raise RuntimeError, ~r/Invalid #{name}/, fn ->
          Config.Reader.read!(path, env: :test)
        end
      after
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end
    end
  end

  defp assert_websocket_upgrade(plug) do
    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    try do
      :ok =
        :gen_tcp.send(
          socket,
          "GET /ws HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        )

      assert {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
      assert response =~ "HTTP/1.1 101"
    after
      :gen_tcp.close(socket)
      stop_supervised!(Bandit)
    end
  end

  defp remote(method, path), do: %{conn(method, path) | remote_ip: {192, 168, 1, 9}}

  defp gateway_connection,
    do:
      Connection.init(peer: {127, 0, 0, 1}, allowed_roles: [:node, :enrollment], tokenless: false)

  defp connect(state, params) do
    frame = Jason.encode!(%{type: "req", id: "connect", method: "connect", params: params})
    Connection.handle_in({frame, [opcode: :text]}, state)
  end
end
