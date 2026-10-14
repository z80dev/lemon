defmodule LemonControlPlane.Methods.NodePairInviteTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.{Authorize, TokenStore}
  alias LemonControlPlane.Methods.{ConnectChallenge, NodePairApprove, NodePairInvite, NodePairRequest, NodesList}
  alias LemonControlPlane.NodeStore
  alias CodingAgent.ExecutionNode.{Socket, Worker}

  @ctx %{auth: %{role: :operator, scopes: [:pairing, :read]}, conn_id: "invite-operator"}

  setup do
    prefix = "invite-test-#{System.unique_integer([:positive])}"
    old = Map.new([:operator_token, :public_ws_url], &{&1, Application.get_env(:lemon_control_plane, &1)})
    Application.put_env(:lemon_control_plane, :operator_token, "invite-test-operator")
    Application.put_env(:lemon_control_plane, :public_ws_url, "wss://controller.example/ws")

    on_exit(fn ->
      for {key, value} <- old do
        if is_nil(value), do: Application.delete_env(:lemon_control_plane, key),
          else: Application.put_env(:lemon_control_plane, key, value)
      end

      for table <- [:node_pair_invites, :nodes_pairing, :node_challenges, :nodes_registry] do
        for {key, row} <- LemonCore.Store.list(table) do
          name = NodeStore.invite_field(row, :node_name) || NodeStore.invite_field(row, :name)
          if is_binary(name) and String.starts_with?(name, prefix) do
            if table == :nodes_registry do
              TokenStore.revoke_identity("node", key)
              LemonCore.Store.delete(:session_token_heads, {"node", key})
              NodeStore.release_node_name(name, key)
            end
            code = NodeStore.invite_field(row, :code)
            if table == :nodes_pairing and is_binary(code),
              do: LemonCore.Store.delete(:nodes_pairing_by_code, code)
            LemonCore.Store.delete(table, key)
          end
        end
      end
    end)

    %{name: prefix}
  end

  test "auto-approves the bound name and delivers real challenge/recovery credentials", %{name: name} do
    :ok = LemonCore.Bus.subscribe("nodes")
    invite = invite(name, %{"labels" => ["office", "mac"]})
    auth = enrollment_auth(invite)
    assert auth.role == :enrollment
    assert auth.scopes == [:enroll]
    refute inspect(auth) =~ invite["inviteCode"]

    assert {:ok, approved} = enroll(invite, name, auth)
    assert approved["approved"]
    assert is_binary(approved["challengeToken"])
    assert is_binary(approved["token"])
    refute inspect(approved["summary"]) =~ approved["token"]
    assert_receive %LemonCore.Event{type: :node_pair_resolved, payload: audit}
    assert Map.keys(audit) |> Enum.sort() == [:approved, :node_id, :pairing_id]
    refute inspect(audit) =~ invite["inviteCode"]

    assert {:ok, exchanged} = ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, %{auth: auth})
    assert {:ok, node_auth} = Authorize.from_params(%{"auth" => %{"token" => exchanged["token"]}}, local?: false)
    assert node_auth.role == :node
    assert node_auth.client_id == approved["nodeId"]
    assert {:error, _} = ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, %{auth: auth})

    assert {:ok, listed} = NodesList.handle(%{}, @ctx)
    row = Enum.find(listed["nodes"], &(&1["id"] == approved["nodeId"]))
    assert row["purpose"] == "lemon_bot"
    assert row["labels"] == ["office", "mac"]
    refute inspect(row) =~ approved["token"]
    assert {:error, _} = enroll(invite, name, auth)
    assert {:error, _} = Authorize.from_params(%{"role" => "enrollment", "auth" => %{"inviteCode" => invite["inviteCode"]}}, local?: false)
  end

  test "consumption is atomic across concurrent enrollment requests", %{name: name} do
    invite = invite(name)
    auth = enrollment_auth(invite)
    tasks = for _ <- 1..12, do: Task.async(fn -> enroll(invite, name, auth) end)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 11
    assert Enum.count(NodeStore.list_nodes(), fn {_id, row} -> NodeStore.invite_field(row, :name) == name end) == 1
  end

  test "wrong name and recovery parameters cannot consume or retarget an invite", %{name: name} do
    invite = invite(name, %{"purpose" => "research", "labels" => ["private"]})
    auth = enrollment_auth(invite)
    assert {:error, _} = enroll(invite, name <> "-wrong", auth)
    assert {:error, _} = NodePairRequest.handle(%{"nodeName" => name, "inviteCode" => invite["inviteCode"], "repair" => true}, %{auth: auth})
    assert {:ok, approved} = enroll(invite, name, auth)
    node = NodeStore.get_node(approved["nodeId"])
    assert node.purpose == "research"
    assert node.labels == ["private"]
  end

  test "expired invites fail authentication and an already connected enrollment", %{name: name} do
    invite = invite(name)
    auth = enrollment_auth(invite)
    assert {:ok, stored} = NodeStore.fetch_invite(invite["inviteCode"])
    key = :crypto.hash(:sha256, invite["inviteCode"]) |> Base.encode16(case: :lower)
    :ok = LemonCore.Store.put(:node_pair_invites, key, Map.put(stored, :expires_at_ms, System.system_time(:millisecond) - 1))
    assert {:error, _} = NodeStore.fetch_invite(invite["inviteCode"])
    assert {:error, _} = enroll(invite, name, auth)
    assert {:error, _} = Authorize.from_params(%{"role" => "enrollment", "auth" => %{"inviteCode" => invite["inviteCode"]}}, local?: false)
  end

  test "restricted credentials cannot claim operator scopes or generic method access", %{name: name} do
    invite = invite(name)
    assert {:ok, auth} = Authorize.from_params(%{"role" => "operator", "scopes" => ["operator.admin", "operator.pairing"], "auth" => %{"inviteCode" => invite["inviteCode"]}}, local?: false)
    assert auth.role == :enrollment
    for {method, scopes} <- [{"nodes.list", [:read]}, {"node.pair.invite", [:pairing]}, {"node.pair.approve", [:pairing]}, {"config.set", [:admin]}, {"node.invoke", [:write]}, {"health", []}] do
      assert {:error, _} = Authorize.authorize(auth, method, scopes)
    end
    assert {:error, _} = NodePairInvite.handle(%{"nodeName" => name}, %{auth: auth})
    assert {:error, _} = NodePairRequest.handle(%{"nodeName" => name}, %{})
    assert {:error, _} = Authorize.from_params(%{"role" => "enrollment"}, local?: true)
    assert {:error, _} = Authorize.from_params(%{"role" => "operator"}, local?: false)
  end

  test "enrollment challenge exchange is bound to the authenticated invite", %{name: name} do
    first = invite(name <> "-first")
    second = invite(name <> "-second")
    first_auth = enrollment_auth(first)
    second_auth = enrollment_auth(second)
    assert {:ok, approved} = enroll(first, name <> "-first", first_auth)
    assert {:error, _} = NodePairApprove.handle(%{"pairingId" => approved["pairingId"]}, %{auth: second_auth})
    assert {:error, _} = ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, %{auth: second_auth})
    assert {:ok, _} = ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, %{auth: first_auth})
  end

  test "operator-authorized recovery retains durable invite purpose and labels", %{name: name} do
    invite = invite(name, %{"purpose" => "research", "labels" => ["office"]})
    auth = enrollment_auth(invite)
    assert {:ok, approved} = enroll(invite, name, auth)
    assert {:ok, requested} = NodePairRequest.handle(%{
      "nodeId" => approved["nodeId"], "nodeName" => "stale-local-alias",
      "recoveryToken" => approved["token"]
    }, @ctx)
    assert {:ok, recovered} = NodePairApprove.handle(%{"pairingId" => requested["pairingId"]}, @ctx)
    assert recovered["nodeId"] == approved["nodeId"]
    assert recovered["summary"]["recovered"]
    refute Map.has_key?(recovered, "token")
    node = NodeStore.get_node(recovered["nodeId"])
    assert node.purpose == "research"
    assert node.labels == ["office"]
  end

  @tag :tmp_dir
  test "validates bounds and quotes a runnable installer-compatible command", %{name: name, tmp_dir: tmp_dir} do
    invite = invite(name <> "'s machine")
    command = invite["joinCommand"]
    assert command =~ "install.sh"
    assert command =~ "--skip-setup --no-modify-path"
    assert command =~ "node join --name"
    assert command =~ "--invite-code"
    assert command =~ "'\\''s machine'"
    refute command =~ "invite-test-operator"
    refute command =~ "--operator-token"
    # Execute the returned shell command against an argv-recording executable:
    # shell syntax and quoting are exercised, not merely compared as prose.
    executable = Path.join(tmp_dir, "lemon")
    File.write!(executable, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    assert :ok = File.chmod(executable, 0o700)
    assert {output, 0} = System.cmd("sh", ["-c", command],
      env: [{"PATH", tmp_dir <> ":" <> (System.get_env("PATH") || "")}])
    assert String.split(output, "\n", trim: true) == [
      "node", "join", "--name", name <> "'s machine", "--controller",
      "wss://controller.example/ws", "--invite-code", invite["inviteCode"]
    ]
    assert {:ok, stored} = NodeStore.fetch_invite(invite["inviteCode"])
    refute inspect(stored) =~ invite["inviteCode"]
    for params <- [%{"nodeName" => ""}, %{"nodeName" => name, "expiresInMs" => 0}, %{"nodeName" => name, "expiresInMs" => 86_400_001}, %{"nodeName" => name, "labels" => [123]}, %{"nodeName" => name, "labels" => List.duplicate("x", 17)}] do
      assert {:error, _} = NodePairInvite.handle(params, @ctx)
    end
  end

  @tag :tmp_dir
  test "real WebSocket enrollment rejects generic mutations and completes worker enrollment", %{name: name, tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)
    bandit = start_supervised!({Bandit, plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false})
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    url = "ws://127.0.0.1:#{port}/ws"
    Application.put_env(:lemon_control_plane, :public_ws_url, url)
    invite = invite(name)
    {:ok, socket} = Socket.start_link(owner: self(), url: url, connect_params: %{"role" => "enrollment", "auth" => %{"inviteCode" => invite["inviteCode"]}})
    on_exit(fn -> if Process.alive?(socket), do: Socket.stop(socket) end)
    assert_receive {:execution_node_socket, ^socket, {:connected, hello}}, 3_000
    assert hello["auth"]["role"] == "enrollment"
    Socket.request(socket, "config.set", %{"key" => "bad", "value" => true}, :forbidden)
    assert_receive {:execution_node_socket, ^socket, {:response, :forbidden, {:error, _}}}, 3_000
    Socket.request(socket, "node.pair.request", %{"nodeName" => name <> "wrong", "inviteCode" => invite["inviteCode"]}, :wrong_name)
    assert_receive {:execution_node_socket, ^socket, {:response, :wrong_name, {:error, _}}}, 3_000
    {:ok, unauthed} = Socket.start_link(owner: self(), url: url, connect_params: %{"role" => "enrollment"})
    assert_receive {:execution_node_socket, ^unauthed, {:authentication_error, _}}, 3_000
    assert_receive {:EXIT, ^unauthed, {:local, 1008, "authentication failed"}}, 3_000
    {:ok, operator} = Socket.start_link(owner: self(), url: url, connect_params: %{"role" => "operator", "auth" => %{"token" => "invite-test-operator"}})
    on_exit(fn -> if Process.alive?(operator), do: Socket.stop(operator) end)
    assert_receive {:execution_node_socket, ^operator, {:connected, _}}, 3_000

    worker = start_supervised!(%{id: {:invite_worker, name}, start: {Worker, :start_link, [[node_name: name, controller: url, cwd: tmp_dir, invite_code: invite["inviteCode"], token_store_opts: [root: tmp_dir], notify_pid: self()]]}, restart: :temporary})
    assert_receive {:execution_node_worker, ^worker, {:status, :online, node_id}}, 5_000
    assert {:ok, %{id: ^node_id}} = LemonCore.NodeRegistry.resolve(name)
    assert NodeStore.get_node(node_id).purpose == "lemon_bot"
    assert_receive {:execution_node_socket, ^operator, {:event, "node.pair.resolved", event}}, 3_000
    assert event["nodeId"] == node_id
    refute_receive {:execution_node_socket, ^socket, {:event, "node.pair.resolved", _}}, 200
    Socket.stop(socket)
    Socket.stop(operator)
  end

  defp invite(name, extra \\ %{}) do
    assert {:ok, result} = NodePairInvite.handle(Map.merge(%{"nodeName" => name}, extra), @ctx)
    result
  end

  defp enrollment_auth(invite) do
    assert {:ok, auth} = Authorize.from_params(%{"role" => "enrollment", "auth" => %{"inviteCode" => invite["inviteCode"]}}, local?: false)
    auth
  end

  defp enroll(invite, name, auth) do
    NodePairRequest.handle(%{"nodeName" => name, "nodeType" => "coding_agent", "inviteCode" => invite["inviteCode"]}, %{auth: auth})
  end
end
