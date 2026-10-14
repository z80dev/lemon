defmodule LemonControlPlane.Methods.ProfilesSyncTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{ProfilesSync, ProfilesSyncStatus}
  alias CodingAgent.ExecutionNode.ProfileSync
  alias LemonControlPlane.NodeStore
  alias LemonCore.{NodeRegistry, ProfileSnapshot, ProfileStore}

  setup do
    root = Path.join(canonical_tmp(), "lemon-profile-sync-cp-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, home_state_dir: root, global_config: Path.join(root, "config.toml"))
    id = LemonCore.Id.uuid()
    name = "sync-worker-#{System.unique_integer([:positive])}"
    owner = self()
    destination = spawn(fn -> destination(owner) end)
    :ok = NodeStore.put_node(id, %{"id" => id, "name" => name, "type" => "coding_agent"})
    :ok = NodeRegistry.register(id, name, destination, %{})

    on_exit(fn ->
      NodeRegistry.unregister(id, destination)
      Process.exit(destination, :kill)
      LemonCore.Store.delete(:nodes_registry, id)
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
      File.rm_rf!(root)
    end)

    {:ok, root: root, node_id: id, node_name: name, destination: destination,
     ctx: %{conn_pid: self(), auth: %{role: :operator, scopes: [:admin, :read]}}}
  end

  test "forwards trusted persona to current named node and waits for exact destination ack without changing placement", context do
    profile = create(context.node_name)
    workspace = profile["paths"]["workspace"]
    File.write!(Path.join(workspace, "AGENTS.md"), "authoritative agents")
    File.write!(Path.join(workspace, "USER.md"), "source private user")
    File.write!(Path.join(workspace, "MEMORY.md"), "source private memory")
    File.write!(Path.join(workspace, "TOOLS.md"), "source tools")
    before_config = File.read!(ProfileStore.config_path())
    task = Task.async(fn -> ProfilesSync.handle(%{"id" => "persona", "mutationId" => "fixed"}, context.ctx) end)
    assert_receive {:sync_request, destination, request}
    assert destination == context.destination
    assert request["nodeId"] == context.node_id
    assert request["method"] == "node.profile.sync"
    payload = request["args"]
    assert :ok = ProfileSnapshot.validate(payload)
    assert payload["personaInstructions"] == %{"AGENTS.md" => "authoritative agents"}
    assert payload["systemPrompt"] == "controller persona"
    assert payload["model"] == "openai:gpt-5"
    refute inspect(payload) =~ "source private"
    refute inspect(payload) =~ "source tools"
    refute inspect(payload) =~ "source-token"
    refute Map.has_key?(payload, "paths")
    assert Task.yield(task, 0) == nil
    send(destination, {:reply, acknowledgement(payload)})
    assert {:ok, receipt} = Task.await(task)
    assert receipt == Map.put(acknowledgement(payload), "nodeId", context.node_id)
    assert File.read!(ProfileStore.config_path()) == before_config
    assert {:ok, after_profile} = ProfileStore.get("persona")
    assert after_profile["node"] == context.node_name
  end

  test "explicit durable target provisions a local profile without switching placement and preserves null mutation", context do
    create("local")
    task = Task.async(fn -> ProfilesSync.handle(%{"id" => "persona", "nodeId" => context.node_id}, context.ctx) end)
    assert_receive {:sync_request, destination, request}
    assert request["args"]["mutationId"] == nil
    send(destination, {:reply, acknowledgement(request["args"])})
    assert {:ok, %{"acknowledged" => true, "mutationId" => nil}} = Task.await(task)
    assert {:ok, %{"node" => "local"}} = ProfileStore.get("persona")
  end

  test "default named UUID placement and explicit durable UUID target select different nodes", context do
    create(context.node_id)
    other_id = "sync-name-collision-#{System.unique_integer([:positive])}"
    owner = self()
    other_destination = spawn(fn -> destination(owner) end)
    :ok = NodeStore.put_node(other_id, %{"id" => other_id, "name" => context.node_id})
    :ok = NodeRegistry.register(other_id, context.node_id, other_destination, %{})
    on_exit(fn ->
      NodeRegistry.unregister(other_id, other_destination)
      Process.exit(other_destination, :kill)
      LemonCore.Store.delete(:nodes_registry, other_id)
    end)
    task = Task.async(fn -> ProfilesSync.handle(%{"id" => "persona"}, context.ctx) end)
    assert_receive {:sync_request, ^other_destination, request}
    assert request["nodeId"] == other_id
    send(other_destination, {:reply, acknowledgement(request["args"])})
    assert {:ok, %{"nodeId" => ^other_id}} = Task.await(task)
    task = Task.async(fn -> ProfilesSync.handle(%{"id" => "persona", "nodeId" => context.node_id, "mutationId" => "explicit-shadow"}, context.ctx) end)
    assert_receive {:sync_request, destination, request}
    assert destination == context.destination
    assert request["nodeId"] == context.node_id
    send(destination, {:reply, acknowledgement(request["args"])})
    assert {:ok, %{"nodeId" => node_id}} = Task.await(task)
    assert node_id == context.node_id
    assert {:ok, %{"node" => ^node_id}} = ProfileStore.get("persona")
    task = Task.async(fn -> ProfilesSyncStatus.handle(%{"id" => "persona", "nodeId" => context.node_id, "mutationId" => "explicit-shadow"}, context.ctx) end)
    assert_receive {:sync_request, ^destination, lookup}
    assert lookup["nodeId"] == context.node_id
    assert lookup["method"] == "node.profile.sync.status"
    send(destination, {:reply, Map.merge(lookup["args"], %{"status" => "acknowledged", "acknowledged" => true})})
    assert {:ok, %{"nodeId" => ^node_id, "status" => "acknowledged"}} = Task.await(task)
  end

  test "configured offline name shadow never falls back to an online durable ID", context do
    create(context.node_id)
    other_id = "sync-offline-shadow-#{System.unique_integer([:positive])}"
    :ok = NodeStore.put_node(other_id, %{"id" => other_id, "name" => context.node_id})
    on_exit(fn -> LemonCore.Store.delete(:nodes_registry, other_id) end)
    assert {:error, {:unavailable, _, _}} = ProfilesSync.handle(%{"id" => "persona"}, context.ctx)
    refute_receive {:sync_request, _, _}
  end

  test "current placement falls back to its durable ID only when no configured name matches", context do
    create(context.node_id)
    task = Task.async(fn -> ProfilesSync.handle(%{"id" => "persona"}, context.ctx) end)
    assert_receive {:sync_request, destination, request}
    assert destination == context.destination
    assert request["nodeId"] == context.node_id
    send(destination, {:reply, acknowledgement(request["args"])})
    assert {:ok, %{"nodeId" => node_id}} = Task.await(task)
    assert node_id == context.node_id
  end

  test "mismatched profile, mutation, digest, absent null and false ack fail closed with bounded errors", context do
    create(context.node_name)
    for change <- [
          fn ack -> Map.put(ack, "profileId", "another") end,
          fn ack -> Map.put(ack, "mutationId", "wrong") end,
          fn ack -> Map.put(ack, "revisionDigest", "wrong") end,
          fn ack -> Map.delete(ack, "mutationId") end,
          fn ack -> Map.put(ack, "acknowledged", false) end
        ] do
      task = Task.async(fn -> ProfilesSync.handle(%{"id" => "persona"}, context.ctx) end)
      assert_receive {:sync_request, destination, request}
      send(destination, {:reply, change.(acknowledgement(request["args"]))})
      assert {:error, {:unavailable, _, %{"reason" => "invalid_acknowledgement", "retrySafe" => false}}} = Task.await(task)
      assert {:ok, %{"node" => node}} = ProfileStore.get("persona")
      assert node == context.node_name
    end
  end

  test "local target omission and nonadmin callers cannot invoke destination", context do
    create("local")
    assert {:error, {:invalid_request, message}} = ProfilesSync.handle(%{"id" => "persona"}, context.ctx)
    assert message =~ "nodeId"
    assert {:error, {:forbidden, _}} = ProfilesSync.handle(%{"id" => "persona", "nodeId" => context.node_id}, %{auth: %{role: :node, scopes: [:admin]}})
    assert {:error, {:forbidden, _}} = ProfilesSync.handle(%{"id" => "persona", "nodeId" => context.node_id}, %{auth: %{role: :operator, scopes: [:read]}})
    assert {:error, {:invalid_request, _}} = ProfilesSync.handle(%{"id" => "persona", "nodeId" => context.node_id, "mutationId" => ""}, context.ctx)
    refute_receive {:sync_request, _, _}
  end

  test "arbitrary destination errors are not reflected into RPC errors", context do
    create(context.node_name)
    task = Task.async(fn -> ProfilesSync.handle(%{"id" => "persona"}, context.ctx) end)
    assert_receive {:sync_request, destination, _request}
    send(destination, {:error, "private /raw/path source-token prompt-text"})
    assert {:error, {:unavailable, _, %{"retrySafe" => false}}} = result = Task.await(task)
    refute inspect(result) =~ "source-token"
    refute inspect(result) =~ "/raw/path"
    refute inspect(result) =~ "prompt-text"
  end

  test "lost sync reply reconciles actual destination receipt without persona resend or placement mutation", context do
    profile = create(context.node_name)
    File.write!(Path.join(profile["paths"]["workspace"], "SOUL.md"), "source soul")
    File.write!(Path.join(profile["paths"]["workspace"], "USER.md"), "private user")
    destination_root = Path.join(context.root, "destination-state")
    config_before = File.read!(ProfileStore.config_path())
    sync = Task.async(fn -> ProfilesSync.handle(%{"id" => "persona", "mutationId" => "lost"}, context.ctx) end)
    assert_receive {:sync_request, destination, request}
    assert {:ok, _lost_ack} = at_destination(destination_root, fn -> ProfileSync.apply(request["args"]) end)
    send(destination, {:error, "acknowledgement_lost"})
    assert {:error, {:unavailable, _, _}} = Task.await(sync)
    receipt_path = Path.join([destination_root, "profiles", "persona", "persona-sync-receipt.json"])
    before_receipt = File.read!(receipt_path)
    status = Task.async(fn ->
      ProfilesSyncStatus.handle(%{"id" => "persona", "nodeId" => context.node_id, "mutationId" => "lost"}, context.ctx)
    end)
    assert_receive {:sync_request, ^destination, lookup}
    assert lookup["method"] == "node.profile.sync.status"
    assert Enum.sort(Map.keys(lookup["args"])) == Enum.sort(~w(profileId mutationId revisionDigest))
    refute inspect(lookup["args"]) =~ "source soul"
    refute inspect(lookup["args"]) =~ "private user"
    assert {:ok, receipt} = at_destination(destination_root, fn -> ProfileSync.status(lookup["args"]) end)
    send(destination, {:reply, receipt})
    assert {:ok, %{"status" => "acknowledged", "acknowledged" => true, "nodeId" => node_id}} = Task.await(status)
    assert node_id == context.node_id
    assert File.read!(receipt_path) == before_receipt
    assert File.read!(ProfileStore.config_path()) == config_before
    assert {:ok, %{"node" => node}} = ProfileStore.get("persona")
    assert node == context.node_name
  end

  test "status source revision mismatch is unknown while corrupt receipt storage stays unavailable", context do
    profile = create(context.node_name)
    destination_root = Path.join(context.root, "destination-state")
    {:ok, snapshot} = ProfileStore.persona_snapshot("persona")
    {:ok, payload} = ProfileSnapshot.build(snapshot, "fixed")
    assert {:ok, _} = at_destination(destination_root, fn -> ProfileSync.apply(payload) end)
    File.write!(Path.join(profile["paths"]["workspace"], "SOUL.md"), "new source")
    query = %{"id" => "persona", "nodeId" => context.node_id, "mutationId" => "fixed"}
    task = Task.async(fn -> ProfilesSyncStatus.handle(query, context.ctx) end)
    assert_receive {:sync_request, destination, request}
    refute request["args"]["revisionDigest"] == payload["revisionDigest"]
    assert {:ok, %{"status" => "unknown", "revisionDigest" => nil} = receipt} =
             at_destination(destination_root, fn -> ProfileSync.status(request["args"]) end)
    send(destination, {:reply, receipt})
    assert {:ok, %{"status" => "unknown", "acknowledged" => false}} = Task.await(task)
    File.write!(Path.join([destination_root, "profiles", "persona", "persona-sync-receipt.json"]), "{corrupt")
    task = Task.async(fn -> ProfilesSyncStatus.handle(query, context.ctx) end)
    assert_receive {:sync_request, ^destination, request}
    assert {:error, :profile_sync_corrupt} = at_destination(destination_root, fn -> ProfileSync.status(request["args"]) end)
    send(destination, {:error, "profile_sync_corrupt"})
    assert {:error, {:unavailable, _}} = Task.await(task)
  end

  test "status rejects wrong correlation and unsafe acknowledgements rather than returning unknown", context do
    create(context.node_name)
    query = %{"id" => "persona", "nodeId" => context.node_id, "mutationId" => "fixed"}
    for change <- [
          fn receipt -> Map.put(receipt, "profileId", "wrong") end,
          fn receipt -> Map.put(receipt, "mutationId", "wrong") end,
          fn receipt -> Map.put(receipt, "revisionDigest", "wrong") end,
          fn receipt -> Map.put(receipt, "acknowledged", false) end
        ] do
      task = Task.async(fn -> ProfilesSyncStatus.handle(query, context.ctx) end)
      assert_receive {:sync_request, destination, request}
      receipt = Map.merge(request["args"], %{"status" => "acknowledged", "acknowledged" => true})
      send(destination, {:reply, change.(receipt)})
      assert {:error, {:unavailable, _}} = Task.await(task)
    end
  end

  test "status is read-scoped async operator RPC with required correlation", context do
    create("local")
    assert ProfilesSyncStatus.scopes() == [:read]
    assert ProfilesSyncStatus.dispatch_mode() == :async
    assert LemonControlPlane.Auth.Authorize.required_scopes("profiles.sync.status") == [:read]
    assert LemonControlPlane.Methods.Registry.lookup("profiles.sync.status") == {:ok, ProfilesSyncStatus}
    assert :ok = LemonControlPlane.Protocol.Schemas.validate("profiles.sync.status", %{"id" => "persona", "nodeId" => context.node_id, "mutationId" => "fixed"})
    assert {:error, {:invalid_request, _}} = ProfilesSyncStatus.handle(%{"id" => "persona", "nodeId" => context.node_id, "mutationId" => nil}, context.ctx)
    assert {:error, {:forbidden, _}} = ProfilesSyncStatus.handle(%{"id" => "persona", "nodeId" => context.node_id, "mutationId" => "fixed"}, %{auth: %{role: :node, scopes: [:read]}})
    assert {:error, {:forbidden, _}} = ProfilesSyncStatus.handle(%{"id" => "persona", "nodeId" => context.node_id, "mutationId" => "fixed"}, %{auth: %{role: :operator, scopes: [:admin]}})
    assert {:error, _} = LemonControlPlane.Protocol.Schemas.validate("profiles.sync.status", %{"id" => "persona", "nodeId" => context.node_id})
    refute_receive {:sync_request, _, _}
  end

  test "method declares admin asynchronous dispatch" do
    assert ProfilesSync.scopes() == [:admin]
    assert ProfilesSync.dispatch_mode() == :async
  end

  defp create(node) do
    {:ok, profile} = ProfileStore.create(%{
      "id" => "persona", "node" => node, "systemPrompt" => "controller persona", "model" => "openai:gpt-5",
      "mcpServers" => [%{"name" => "private", "url" => "https://example.test/mcp", "headers" => %{"Authorization" => "Bearer source-token"}}]
    })
    profile
  end

  defp acknowledgement(payload), do: Map.take(payload, ~w(profileId mutationId revisionDigest)) |> Map.put("acknowledged", true)

  defp destination(owner) do
    receive do
      {:node_event, "node.invoke.request", request} ->
        send(owner, {:sync_request, self(), request})
        receive do
          {:reply, ack} -> NodeRegistry.complete_session(request["nodeId"], self(), 0, request["invokeId"], ack, nil)
          {:error, error} -> NodeRegistry.complete_session(request["nodeId"], self(), 0, request["invokeId"], nil, error)
        end
        destination(owner)
      _ -> destination(owner)
    end
  end

  defp at_destination(root, fun) do
    previous = Application.fetch_env!(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, home_state_dir: root, global_config: Path.join(root, "config.toml"))
    try do
      fun.()
    after
      Application.put_env(:lemon_core, :paths, previous)
    end
  end

  defp canonical_tmp do
    System.tmp_dir!()
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn part, parent ->
      path = Path.join(parent, part)
      case File.read_link(path) do
        {:ok, target} -> Path.expand(target, parent)
        _ -> path
      end
    end)
  end
end
