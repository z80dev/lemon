defmodule LemonControlPlane.Methods.NodePairInviteTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.{Authorize, TokenStore}
  alias LemonControlPlane.Methods.{ConnectChallenge, NodePairApprove, NodePairInvite, NodePairInviteRevoke, NodePairRequest, NodesList}
  alias LemonControlPlane.NodeStore
  alias CodingAgent.ExecutionNode.{Socket, Worker}

  @ctx %{auth: %{role: :operator, scopes: [:pairing, :read]}, conn_id: "invite-operator"}
  @moduletag :tmp_dir
  @runtime_keys [:node_source_checkout, :node_install_version, :node_install_base_url]
  @runtime_env [
    "LEMON_NODE_SOURCE_CHECKOUT",
    "LEMON_NODE_INSTALL_VERSION",
    "LEMON_NODE_INSTALL_BASE_URL",
    "LEMON_VERSION",
    "RELEASE_VSN",
    "LEMON_INSTALL_BASE_URL"
  ]

  setup %{tmp_dir: tmp_dir} do
    prefix = "invite-test-#{System.unique_integer([:positive])}"
    old = Map.new([:operator_token, :public_ws_url] ++ @runtime_keys,
      &{&1, Application.get_env(:lemon_control_plane, &1)})
    old_env = Map.new(@runtime_env, &{&1, System.get_env(&1)})
    Enum.each(@runtime_env, &System.delete_env/1)
    Enum.each(@runtime_keys, &Application.delete_env(:lemon_control_plane, &1))
    Application.put_env(:lemon_control_plane, :operator_token, "invite-test-operator")
    Application.put_env(:lemon_control_plane, :public_ws_url, "wss://controller.example/ws")
    Application.put_env(:lemon_control_plane, :node_source_checkout, Path.join(tmp_dir, "destination source"))

    on_exit(fn ->
      for {key, value} <- old do
        if is_nil(value), do: Application.delete_env(:lemon_control_plane, key),
          else: Application.put_env(:lemon_control_plane, key, value)
      end
      for {key, value} <- old_env do
        if is_nil(value), do: System.delete_env(key), else: System.put_env(key, value)
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
    invite = invite(name, %{"labels" => %{"location" => "office", "platform" => "mac"}})
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
    assert row["labels"] == %{"location" => "office", "platform" => "mac"}
    assert row["enrollmentInviteId"] == invite["inviteId"]
    assert NodeStore.get_node(approved["nodeId"]).enrollment_invite_id == invite["inviteId"]
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
    invite = invite(name, %{"purpose" => "research", "labels" => %{"visibility" => "private"}})
    auth = enrollment_auth(invite)
    assert {:error, _} = enroll(invite, name <> "-wrong", auth)
    assert {:error, _} = NodePairRequest.handle(%{"nodeName" => name, "inviteCode" => invite["inviteCode"], "repair" => true}, %{auth: auth})
    assert {:ok, approved} = enroll(invite, name, auth)
    node = NodeStore.get_node(approved["nodeId"])
    assert node.purpose == "research"
    assert node.labels == %{"visibility" => "private"}
  end

  test "expired invites fail authentication and an already connected enrollment", %{name: name} do
    invite = invite(name)
    auth = enrollment_auth(invite)
    assert {:error, _} = enroll(invite, name <> "-wrong", auth)
    assert {:ok, stored} = NodeStore.fetch_invite(invite["inviteCode"])
    key = :crypto.hash(:sha256, invite["inviteCode"]) |> Base.encode16(case: :lower)
    :ok = LemonCore.Store.put(:node_pair_invites, key, Map.put(stored, :expires_at_ms, System.system_time(:millisecond) - 1))
    assert {:error, _} = NodeStore.fetch_invite(invite["inviteCode"])
    assert {:error, {:not_found, _}} = NodePairInviteRevoke.handle(%{"inviteId" => invite["inviteId"]}, @ctx)
    assert {:error, _} = enroll(invite, name, auth)
    assert {:error, _} = Authorize.from_params(%{"role" => "enrollment", "auth" => %{"inviteCode" => invite["inviteCode"]}}, local?: false)
    replacement = invite(name)
    assert {:ok, _} = enroll(replacement, name, enrollment_auth(replacement))
  end

  test "restricted credentials cannot claim operator scopes or generic method access", %{name: name} do
    invite = invite(name)
    assert {:ok, auth} = Authorize.from_params(%{"role" => "operator", "scopes" => ["operator.admin", "operator.pairing"], "auth" => %{"inviteCode" => invite["inviteCode"]}}, local?: false)
    assert auth.role == :enrollment
    for {method, scopes} <- [{"nodes.list", [:read]}, {"node.pair.invite", [:pairing]}, {"node.pair.invite.revoke", [:pairing]}, {"node.pair.approve", [:pairing]}, {"config.set", [:admin]}, {"node.invoke", [:write]}, {"health", []}] do
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
    invite = invite(name, %{"purpose" => "research", "labels" => %{"location" => "office"}})
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
    assert node.labels == %{"location" => "office"}
    assert node.enrollment_invite_id == invite["inviteId"]
  end

  test "repair invitation retains the durable ID and metadata and rotates credentials", %{name: name} do
    original = invite(name, %{"purpose" => "research", "labels" => %{"site" => "office"}})
    original_auth = enrollment_auth(original)
    assert {:ok, approved} = enroll(original, name, original_auth)
    node_id = approved["nodeId"]
    assert {:ok, session} = ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, %{auth: original_auth})
    repair = invite(name, %{"nodeId" => node_id})
    competing = invite(name, %{"nodeId" => node_id})
    auth = enrollment_auth(repair)
    competing_auth = enrollment_auth(competing)
    assert {:error, {:unauthorized, _}} = enroll(repair, name <> "-wrong", auth)
    assert {:ok, recovered} = enroll(repair, name, auth)
    assert recovered["nodeId"] == node_id
    assert recovered["summary"]["recovered"]
    assert recovered["token"] != approved["token"]
    assert {:error, {:unauthorized, _}} = enroll(competing, name, competing_auth)
    assert {:error, _} = Authorize.from_params(%{"auth" => %{"inviteCode" => competing["inviteCode"]}}, local?: false)
    assert {:ok, exchanged} = ConnectChallenge.handle(%{"challenge" => recovered["challengeToken"]}, %{auth: auth})
    assert exchanged["identity"]["nodeId"] == node_id
    assert {:error, :invalid_token} = TokenStore.validate(session["token"])
    assert {:ok, _} = TokenStore.validate(exchanged["token"])
    node = NodeStore.get_node(node_id)
    assert node.purpose == "research"
    assert node.labels == %{"site" => "office"}
    assert node.enrollment_invite_id == repair["inviteId"]
    assert Enum.count(NodeStore.list_nodes(), fn {_id, row} -> NodeStore.invite_field(row, :name) == name end) == 1
    assert {:ok, listed} = NodesList.handle(%{}, @ctx)
    assert Enum.find(listed["nodes"], &(&1["id"] == node_id))["labels"] == %{"site" => "office"}
    assert Enum.find(listed["nodes"], &(&1["id"] == node_id))["enrollmentInviteId"] == repair["inviteId"]
  end

  test "session rotation and revocation make already-authenticated repair invites stale", %{name: name} do
    original = invite(name)
    auth = enrollment_auth(original)
    assert {:ok, approved} = enroll(original, name, auth)
    node_id = approved["nodeId"]
    recovery_hash = NodeStore.get_node(node_id).token_hash
    repair = invite(name, %{"nodeId" => node_id})
    repair_auth = enrollment_auth(repair)
    # A session issued after invitation creation changes generation zero to one.
    assert {:ok, _} = ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, %{auth: auth})
    assert {:error, {:unauthorized, _}} = enroll(repair, name, repair_auth)
    assert {:error, _} = NodeStore.fetch_invite(repair["inviteCode"])
    fresh = invite(name, %{"nodeId" => node_id})
    fresh_auth = enrollment_auth(fresh)
    assert {:ok, _} = TokenStore.revoke_identity("node", node_id)
    assert {:error, {:unauthorized, _}} = enroll(fresh, name, fresh_auth)
    assert {:error, _} = Authorize.from_params(%{"auth" => %{"inviteCode" => fresh["inviteCode"]}}, local?: false)
    assert NodeStore.get_node(node_id).token_hash == recovery_hash
  end

  test "repair challenge cannot restore a generation revoked after auto-approval", %{name: name} do
    original = invite(name)
    original_auth = enrollment_auth(original)
    assert {:ok, approved} = enroll(original, name, original_auth)
    repair = invite(name, %{"nodeId" => approved["nodeId"]})
    auth = enrollment_auth(repair)
    assert {:ok, repaired} = enroll(repair, name, auth)
    assert {:error, {:unauthorized, _}} =
      ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, %{auth: original_auth})
    assert {:ok, _} = TokenStore.revoke_identity("node", approved["nodeId"])
    assert {:error, {:unauthorized, _}} =
      ConnectChallenge.handle(%{"challenge" => repaired["challengeToken"]}, %{auth: auth})
    assert {:error, {:unauthorized, _}} =
      NodePairApprove.handle(%{"pairingId" => repaired["pairingId"]}, @ctx)
  end

  test "revocation invalidates pending codes without unpairing their bound node", %{name: name} do
    original = invite(name)
    auth = enrollment_auth(original)
    assert {:ok, approved} = enroll(original, name, auth)
    assert {:ok, session} = ConnectChallenge.handle(%{"challenge" => approved["challengeToken"]}, %{auth: auth})
    repair = invite(name, %{"nodeId" => approved["nodeId"]})
    repair_auth = enrollment_auth(repair)
    assert {:error, _} = NodePairInviteRevoke.handle(%{"inviteId" => repair["inviteId"]}, %{auth: repair_auth})
    assert {:ok, %{"inviteId" => id, "revoked" => true}} =
      NodePairInviteRevoke.handle(%{"inviteId" => repair["inviteId"]}, @ctx)
    assert id == repair["inviteId"]
    assert {:error, {:unauthorized, _}} = enroll(repair, name, repair_auth)
    assert {:error, _} = Authorize.from_params(%{"auth" => %{"inviteCode" => repair["inviteCode"]}}, local?: false)
    assert {:ok, _} = TokenStore.validate(session["token"])
    assert is_map(NodeStore.get_node(approved["nodeId"]))
    for absent <- [id, original["inviteId"], LemonCore.Id.uuid()] do
      assert {:error, {:not_found, _}} = NodePairInviteRevoke.handle(%{"inviteId" => absent}, @ctx)
    end
    assert {:error, {:invalid_request, _}} = NodePairInviteRevoke.handle(%{}, @ctx)
  end

  test "repair issuance rejects a missing ID or a mismatched durable name", %{name: name} do
    assert {:error, {:not_found, _}} =
      NodePairInvite.handle(%{"nodeName" => name, "nodeId" => LemonCore.Id.uuid()}, @ctx)
    original = invite(name)
    assert {:ok, approved} = enroll(original, name, enrollment_auth(original))
    assert {:error, {:conflict, _}} =
      NodePairInvite.handle(%{"nodeName" => name <> "-other", "nodeId" => approved["nodeId"]}, @ctx)
    assert {:error, {:invalid_request, _}} =
      NodePairInvite.handle(%{"nodeName" => name, "nodeId" => 42}, @ctx)
  end

  test "label maps preserve exact strings at the byte and key-count limits", %{name: name} do
    labels = Map.new(1..31, &{"key#{&1}", ""})
      |> Map.put(String.duplicate("k", 64), String.duplicate("v", 256))
    original = invite(name, %{"labels" => labels})
    assert {:ok, approved} = enroll(original, name, enrollment_auth(original))
    assert NodeStore.get_node(approved["nodeId"]).labels == labels
    assert {:ok, listed} = NodesList.handle(%{}, @ctx)
    assert Enum.find(listed["nodes"], &(&1["id"] == approved["nodeId"]))["labels"] == labels
  end


  test "issued commands contain no enrollment or operator authority", %{name: name} do
    issued = invite(name)
    refute issued["joinCommand"] =~ issued["inviteCode"]
    refute issued["joinCommand"] =~ "invite-test-operator"
    assert issued["joinCommand"] =~ "scripts/join-node.sh"
    assert issued["joinCommand"] =~ "--source"
    refute issued["joinCommand"] =~ "curl"
    assert {:ok, stored} = NodeStore.fetch_invite(issued["inviteCode"])
    refute inspect(stored) =~ issued["inviteCode"]
  end


  test "loopback source defaults can issue restricted invitations", %{name: name} do
    Application.delete_env(:lemon_control_plane, :node_source_checkout)
    for controller <- ["ws://127.0.0.1:4040/ws", "ws://localhost:4040/ws", "ws://[::1]:4040/ws"] do
      Application.put_env(:lemon_control_plane, :public_ws_url, controller)
      issued = invite(name)
      assert enrollment_auth(issued).role == :enrollment
    end
  end
  test "remote invites require a destination source or complete explicit release prerequisites",
       %{name: name} do
    Application.delete_env(:lemon_control_plane, :node_source_checkout)
    error = "Configure a destination source checkout or an explicit node install version and HTTPS base URL"
    assert {:error, {:invalid_request, ^error}} = NodePairInvite.handle(%{"nodeName" => name}, @ctx)
    Application.put_env(:lemon_control_plane, :node_install_version, "2099.01.7-private")
    assert {:error, {:invalid_request, ^error}} = NodePairInvite.handle(%{"nodeName" => name}, @ctx)
    for base <- ["http://releases.example", "https://user:secret@releases.example",
                 "https://releases.example?token=secret", "https://releases.example/#fragment"] do
      Application.put_env(:lemon_control_plane, :node_install_base_url, base)
      assert {:error, {:invalid_request, ^error}} = NodePairInvite.handle(%{"nodeName" => name}, @ctx)
    end
    refute Enum.any?(LemonCore.Store.list(:node_pair_invites), fn {_id, row} ->
      NodeStore.invite_field(row, :node_name) == name
    end)
  end

  test "source environment accepts an absolute worker-local path without probing it on the controller",
       %{name: name} do
    Application.delete_env(:lemon_control_plane, :node_source_checkout)
    System.put_env("LEMON_NODE_SOURCE_CHECKOUT", "/srv/operator provisioned/lemon")
    issued = invite(name)
    assert enrollment_auth(issued).role == :enrollment
    System.put_env("LEMON_NODE_SOURCE_CHECKOUT", "relative/lemon")
    assert {:error, {:invalid_request, "Configure an absolute destination node source checkout"}} =
      NodePairInvite.handle(%{"nodeName" => name}, @ctx)
  end

  test "release prerequisites issue a restricted invitation without embedding its code", %{name: name} do
    Application.delete_env(:lemon_control_plane, :node_source_checkout)
    Application.put_env(:lemon_control_plane, :node_install_version, "2099.01.7-private")
    Application.put_env(:lemon_control_plane, :node_install_base_url, "https://releases.example/lemon")
    issued = invite(name)
    assert enrollment_auth(issued).role == :enrollment
    refute issued["joinCommand"] =~ issued["inviteCode"]
    assert issued["joinCommand"] =~ "https://releases.example/lemon/releases/download/v2099.01.7-private/join-node.sh"
    assert issued["joinCommand"] =~ "'--version' '2099.01.7-private'"
    assert issued["joinCommand"] =~ "'--base-url' 'https://releases.example/lemon'"
    refute issued["joinCommand"] =~ "/main/"
    refute issued["joinCommand"] =~ "--source"
    Application.put_env(:lemon_control_plane, :node_install_version, "latest")
    assert {:error, {:invalid_request, "Configure an exact node install version"}} =
      NodePairInvite.handle(%{"nodeName" => name}, @ctx)
  end

  test "packaged release mode pins the running version and ignores the compiled checkout",
       %{name: name} do
    # This module is compiled inside a source checkout, so its compile-time checkout
    # path is non-nil -- exactly what a CI-built release BEAM carries. The runtime
    # release signal must win, even for a configured checkout and a loopback controller.
    System.put_env("RELEASE_VSN", "2099.01.7-private")
    for controller <- ["wss://controller.example/ws", "ws://127.0.0.1:4040/ws"] do
      Application.put_env(:lemon_control_plane, :public_ws_url, controller)
      assert {:ok, issued} = NodePairInvite.handle(%{"nodeName" => name}, @ctx)
      assert issued["joinCommand"] =~
        "https://github.com/z80dev/lemon/releases/download/v2099.01.7-private/join-node.sh"
      assert issued["joinCommand"] =~ "'--version' '2099.01.7-private'"
      assert issued["joinCommand"] =~ "'--base-url' 'https://github.com/z80dev/lemon'"
      refute issued["joinCommand"] =~ "--source"
      refute issued["joinCommand"] =~ Path.expand("../../../../..", __DIR__)
      refute issued["joinCommand"] =~ "/main/"
      assert enrollment_auth(issued).role == :enrollment
    end

    # An operator override remains authoritative for a packaged controller.
    Application.put_env(:lemon_control_plane, :node_install_version, "2099.01.8-private")
    Application.put_env(:lemon_control_plane, :node_install_base_url, "https://releases.example/lemon")
    assert {:ok, issued} = NodePairInvite.handle(%{"nodeName" => name}, @ctx)
    assert issued["joinCommand"] =~ "https://releases.example/lemon/releases/download/v2099.01.8-private/join-node.sh"
  end

  test "source mode keeps the explicit checkout and never emits a release download", %{name: name} do
    assert System.get_env("RELEASE_VSN") == nil
    issued = invite(name)
    assert issued["joinCommand"] =~ "bash '"
    assert issued["joinCommand"] =~ "destination source"
    assert issued["joinCommand"] =~ "'--source'"
    refute issued["joinCommand"] =~ "curl"
    refute issued["joinCommand"] =~ "github.com"
  end

  test "validates invitation bounds", %{name: name} do
    for params <- [
      %{"nodeName" => ""},
      %{"nodeName" => name, "expiresInMs" => 0},
      %{"nodeName" => name, "expiresInMs" => 86_400_001},
      %{"nodeName" => name, "labels" => ["retired-list-label"]},
      %{"nodeName" => name, "labels" => %{123 => "value"}},
      %{"nodeName" => name, "labels" => %{"key" => 123}},
      %{"nodeName" => name, "labels" => %{String.duplicate("k", 65) => "value"}},
      %{"nodeName" => name, "labels" => %{"key" => String.duplicate("v", 257)}},
      %{"nodeName" => name, "labels" => %{"\n" => "value"}},
      %{"nodeName" => name, "labels" => %{"key" => "\n"}},
      %{"nodeName" => name, "labels" => Map.new(1..33, &{"key#{&1}", "value"})}
    ] do
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
    assert {:ok, saved} = CodingAgent.ExecutionNode.TokenStore.load_node(node_id, root: tmp_dir, controller: url)
    assert :ok = stop_supervised({:invite_worker, name})
    Socket.request(operator, "node.pair.invite", %{"nodeId" => node_id, "nodeName" => name}, :repair_invite)
    assert_receive {:execution_node_socket, ^operator, {:response, :repair_invite, {:ok, repair}}}, 3_000
    repaired_worker = start_supervised!(%{id: {:repair_worker, name}, start: {Worker, :start_link, [[node_name: name, controller: url, cwd: tmp_dir, invite_code: repair["inviteCode"], token_store_opts: [root: tmp_dir], notify_pid: self()]]}, restart: :temporary})
    assert_receive {:execution_node_worker, ^repaired_worker, {:status, :online, ^node_id}}, 5_000
    assert {:ok, %{id: ^node_id}} = LemonCore.NodeRegistry.resolve_id(node_id)
    assert {:ok, repaired_saved} = CodingAgent.ExecutionNode.TokenStore.load_node(node_id, root: tmp_dir, controller: url)
    assert repaired_saved["nodeId"] == saved["nodeId"]
    Socket.request(operator, "nodes.list", %{"name" => name, "nodeId" => node_id}, :repaired_inventory)
    assert_receive {:execution_node_socket, ^operator, {:response, :repaired_inventory, {:ok, inventory}}}, 3_000
    assert [%{"id" => ^node_id, "enrollmentInviteId" => proof}] = inventory["nodes"]
    assert proof == repair["inviteId"]
    refute inventory["summary"]["truncated"]
    assert repaired_saved["token"] != saved["token"]
    assert repaired_saved["recoveryToken"] != saved["recoveryToken"]
    assert {:error, :invalid_token} = TokenStore.validate(saved["token"])
    assert :ok = stop_supervised({:repair_worker, name})
    reconnected = start_supervised!(%{id: {:reconnect_worker, name}, start: {Worker, :start_link, [[node_name: name, controller: url, cwd: tmp_dir, token_store_opts: [root: tmp_dir], notify_pid: self()]]}, restart: :temporary})
    assert_receive {:execution_node_worker, ^reconnected, {:status, :online, ^node_id}}, 5_000

    pending = invite(name <> "-revoked")
    Socket.request(operator, "node.pair.invite.revoke", %{"inviteId" => pending["inviteId"]}, :revoke_invite)
    assert_receive {:execution_node_socket, ^operator, {:response, :revoke_invite, {:ok, revoked}}}, 3_000
    assert revoked == %{"inviteId" => pending["inviteId"], "revoked" => true}
    Socket.request(operator, "node.pair.invite.revoke", %{"inviteId" => pending["inviteId"]}, :revoke_again)
    assert_receive {:execution_node_socket, ^operator, {:response, :revoke_again, {:error, %{"code" => "NOT_FOUND"}}}}, 3_000
    assert {:ok, %{id: ^node_id}} = LemonCore.NodeRegistry.resolve_id(node_id)
    Socket.stop(socket)
    Socket.stop(operator)
  end

  test "deleted bound identity cannot silently become a replacement node", %{name: name} do
    original = invite(name)
    assert {:ok, approved} = enroll(original, name, enrollment_auth(original))
    node_id = approved["nodeId"]
    repair = invite(name, %{"nodeId" => node_id})
    auth = enrollment_auth(repair)
    assert :ok = LemonCore.Store.delete(:nodes_registry, node_id)
    assert :ok = NodeStore.release_node_name(name, node_id)
    assert {:error, {:unauthorized, _}} = enroll(repair, name, auth)
    assert {:error, _} = NodeStore.fetch_invite(repair["inviteCode"])
    refute Enum.any?(NodeStore.list_nodes(), fn {_id, row} -> NodeStore.invite_field(row, :name) == name end)
  end

  test "repair invitation survives JSON reload and explicitly replaces map metadata", %{name: name} do
    original = invite(name, %{"purpose" => "research", "labels" => %{"site" => "office"}})
    assert {:ok, approved} = enroll(original, name, enrollment_auth(original))
    node_id = approved["nodeId"]
    reloaded_node = NodeStore.get_node(node_id) |> Jason.encode!() |> Jason.decode!()
    assert :ok = NodeStore.put_node(node_id, reloaded_node)
    repair = invite(name, %{"nodeId" => node_id, "purpose" => "operations", "labels" => %{"site" => "studio"}})
    digest = :crypto.hash(:sha256, repair["inviteCode"]) |> Base.encode16(case: :lower)
    assert {:ok, stored} = NodeStore.fetch_invite(repair["inviteCode"])
    assert :ok = LemonCore.Store.put(:node_pair_invites, digest, stored |> Jason.encode!() |> Jason.decode!())
    auth = enrollment_auth(repair)
    assert {:ok, repaired} = enroll(repair, name, auth)
    assert repaired["nodeId"] == node_id
    node = NodeStore.get_node(node_id)
    assert node.purpose == "operations"
    assert node.labels == %{"site" => "studio"}
    refute Map.has_key?(node, "purpose")
    refute Map.has_key?(node, "labels")
    refute Map.has_key?(node, "token_hash")
    assert node.enrollment_invite_id == repair["inviteId"]
    refute Map.has_key?(node, "enrollment_invite_id")
    assert {:ok, exchanged} = ConnectChallenge.handle(%{"challenge" => repaired["challengeToken"]}, %{auth: auth})
    assert exchanged["identity"]["nodeId"] == node_id
  end

  test "exact inventory filters precede the cap and legacy enrollment proof is null", %{name: name} do
    for index <- 1..201 do
      id = LemonCore.Id.uuid()
      assert :ok = NodeStore.put_node(id, %{id: id, name: name <> "-#{index}", type: "generic", labels: %{}})
    end
    target_name = name <> "-zzzz"
    target_id = LemonCore.Id.uuid()
    assert :ok = NodeStore.put_node(target_id, %{"id" => target_id, "name" => target_name, "type" => "generic", "labels" => %{}})
    assert {:ok, all} = NodesList.handle(%{}, @ctx)
    assert all["summary"]["truncated"]
    assert length(all["nodes"]) == 200
    refute Enum.any?(all["nodes"], &(&1["id"] == target_id))
    for filters <- [%{"name" => target_name}, %{"nodeId" => target_id}, %{"name" => target_name, "nodeId" => target_id}] do
      assert {:ok, filtered} = NodesList.handle(filters, @ctx)
      assert [%{"id" => ^target_id, "name" => ^target_name, "enrollmentInviteId" => nil}] = filtered["nodes"]
      refute filtered["summary"]["truncated"]
      assert filtered["summary"]["count"] == 1
    end
    assert {:ok, absent} = NodesList.handle(%{"name" => target_name <> "-absent"}, @ctx)
    assert absent["nodes"] == []
    refute absent["summary"]["truncated"]
    assert {:ok, mismatched} = NodesList.handle(%{"name" => name <> "-1", "nodeId" => target_id}, @ctx)
    assert mismatched["nodes"] == []
    refute mismatched["summary"]["truncated"]
    for filters <- [%{"name" => ""}, %{"name" => 123}, %{"nodeId" => ""}, %{"nodeId" => 123}] do
      assert {:error, {:invalid_request, _}} = NodesList.handle(filters, @ctx)
    end
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
