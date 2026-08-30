defmodule LemonControlPlane.WS.OperatorAuthTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.WS.Connection

  @operator_token "test-control-plane-operator-secret"

  setup do
    previous = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    Application.put_env(:lemon_control_plane, :operator_token, @operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)
    clear_node_tables()

    on_exit(fn ->
      clear_node_tables()

      if is_nil(previous) do
        Application.delete_env(:lemon_control_plane, :operator_token)
      else
        Application.put_env(:lemon_control_plane, :operator_token, previous)
      end

      if is_nil(previous_loopback) do
        Application.delete_env(
          :lemon_control_plane,
          :allow_unauthenticated_loopback_operator
        )
      else
        Application.put_env(
          :lemon_control_plane,
          :allow_unauthenticated_loopback_operator,
          previous_loopback
        )
      end
    end)

    :ok
  end

  test "operator connect rejects missing and wrong tokens without reflecting credentials" do
    assert {:ok, state} = Connection.init(peer: {203, 0, 113, 10})

    assert {:push, {:text, missing_frame}, ^state} =
             connect(state, %{"role" => "operator"}, "missing-token")

    assert %{
             "ok" => false,
             "error" => %{"code" => "UNAUTHORIZED", "message" => "Operator token is required"}
           } = Jason.decode!(missing_frame)

    wrong_token = "do-not-reflect-this-token"

    assert {:push, {:text, wrong_frame}, ^state} =
             connect(
               state,
               %{"role" => "operator", "auth" => %{"token" => wrong_token}},
               "wrong-token"
             )

    assert %{
             "ok" => false,
             "error" => %{"code" => "UNAUTHORIZED", "message" => "Operator token is invalid"}
           } = Jason.decode!(wrong_frame)

    refute missing_frame =~ @operator_token
    refute wrong_frame =~ @operator_token
    refute wrong_frame =~ wrong_token
  end

  test "tokenless loopback compatibility is disabled by default and requires explicit opt-in" do
    Application.delete_env(:lemon_control_plane, :operator_token)

    assert {:ok, default_state} =
             Connection.init(peer: {0, 0, 0, 0, 0, 65_535, 0x7F00, 1})

    assert {:push, {:text, default_frame}, ^default_state} =
             connect(default_state, %{"role" => "operator"}, "default-loopback")

    assert %{
             "ok" => false,
             "error" => %{"code" => "UNAUTHORIZED", "message" => default_message}
           } = Jason.decode!(default_frame)

    assert default_message =~ "Operator authentication is required"

    Application.put_env(
      :lemon_control_plane,
      :allow_unauthenticated_loopback_operator,
      true
    )

    assert {:ok, opted_in_state} =
             Connection.init(peer: {0, 0, 0, 0, 0, 65_535, 0x7F00, 1})

    assert {:push, {:text, loopback_frame}, _connected_state} =
             connect(opted_in_state, %{"role" => "operator"}, "mapped-loopback")

    assert %{"type" => "hello-ok", "auth" => %{"role" => "operator"}} =
             Jason.decode!(loopback_frame)

    assert {:ok, remote_state} =
             Connection.init(peer: {0, 0, 0, 0, 0, 65_535, 0x7EFF, 1})

    assert {:push, {:text, remote_frame}, ^remote_state} =
             connect(remote_state, %{"role" => "operator"}, "mapped-remote")

    assert %{
             "ok" => false,
             "error" => %{"code" => "UNAUTHORIZED", "message" => message}
           } = Jason.decode!(remote_frame)

    assert message =~ "Operator authentication is required"
  end

  test "authenticated operator can request and approve a named node pairing" do
    assert {:ok, state} = Connection.init(peer: {203, 0, 113, 11})

    assert {:push, {:text, hello_frame}, connected_state} =
             connect(
               state,
               %{
                 "role" => "operator",
                 "auth" => %{"token" => @operator_token},
                 "client" => %{"id" => "named-node-pairing-test"}
               },
               "right-token"
             )

    hello = Jason.decode!(hello_frame)
    assert hello["type"] == "hello-ok"
    assert hello["auth"]["role"] == "operator"
    assert "pairing" in hello["auth"]["scopes"]
    assert connected_state.auth.token == nil
    refute inspect(connected_state) =~ @operator_token

    assert {:push, {:text, request_frame}, connected_state} =
             request(
               connected_state,
               "pair-request",
               "node.pair.request",
               %{
                 "nodeType" => "coding_agent",
                 "nodeName" => "Authenticated Worker",
                 "capabilities" => %{"coding_agent.run" => %{"version" => 1}}
               }
             )

    assert %{"ok" => true, "payload" => %{"pairingId" => pairing_id}} =
             Jason.decode!(request_frame)

    assert {:push, {:text, approve_frame}, _connected_state} =
             request(
               connected_state,
               "pair-approve",
               "node.pair.approve",
               %{"pairingId" => pairing_id}
             )

    assert %{
             "ok" => true,
             "payload" => %{
               "approved" => true,
               "challengeToken" => challenge,
               "nodeId" => node_id,
               "token" => node_token
             }
           } = Jason.decode!(approve_frame)

    assert is_binary(challenge) and challenge != ""
    assert is_binary(node_token) and node_token != ""
    refute approve_frame =~ @operator_token

    assert {:push, {:text, invoke_frame}, _connected_state} =
             request(
               connected_state,
               "node-invoke",
               "node.invoke",
               %{"nodeId" => node_id, "method" => "coding_agent.run", "args" => %{}}
             )

    assert %{
             "ok" => false,
             "error" => %{"code" => "UNAVAILABLE", "message" => "Node is not online"}
           } = Jason.decode!(invoke_frame)
  end

  defp connect(state, params, id) do
    frame =
      Jason.encode!(%{
        "type" => "req",
        "id" => id,
        "method" => "connect",
        "params" => params
      })

    Connection.handle_in({frame, [opcode: :text]}, state)
  end

  defp request(state, id, method, params) do
    frame =
      Jason.encode!(%{
        "type" => "req",
        "id" => id,
        "method" => method,
        "params" => params
      })

    Connection.handle_in({frame, [opcode: :text]}, state)
  end

  defp clear_node_tables do
    Enum.each(
      [
        :nodes_pairing,
        :nodes_pairing_by_code,
        :nodes_registry,
        :nodes_by_name,
        :node_challenges,
        :node_invocations,
        :session_tokens
      ],
      fn table ->
        LemonCore.Store.list(table)
        |> Enum.each(fn {key, _value} -> LemonCore.Store.delete(table, key) end)
      end
    )
  end
end
