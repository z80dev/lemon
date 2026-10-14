defmodule LemonControlPlane.Methods.MemoryTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{MemoryAdd, MemoryDelete, MemoryGet, MemoryList, MemorySearch}
  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.Protocol.Schemas
  alias LemonCore.{NodeRegistry, ProfileStore}
  alias LemonMemory.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    state = Path.join(tmp_dir, "state")
    config = Path.join(state, "config.toml")
    File.mkdir_p!(state)
    previous_paths = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, home_state_dir: state, global_config: config)

    store = String.to_atom("profile_memory_cp_#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: store, path: Path.join(tmp_dir, "memory")})

    if Process.whereis(NodeRegistry) == nil, do: start_supervised!(NodeRegistry)
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)

    on_exit(fn ->
      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    {:ok, _} = ProfileStore.create(%{"id" => "memory-alpha"})
    {:ok, _} = ProfileStore.create(%{"id" => "memory-beta"})
    {:ok, ctx: %{memory_opts: [store: store]}}
  end

  test "local profile add, list, search, get and confirmed delete roundtrip", %{ctx: ctx} do
    assert {:ok, %{"item" => item}} =
             MemoryAdd.handle(%{"profileId" => "memory-alpha", "text" => "Prefers jasmine tea"}, ctx)
    id = item["id"]
    assert item["kind"] == "memory"
    assert item["source"] == "workspace"
    assert item["text"] =~ "jasmine"
    assert byte_size(item["text"]) <= 2_048
    assert is_integer(item["createdAtMs"])
    assert is_integer(item["updatedAtMs"])

    assert {:ok, %{"items" => items, "nextCursor" => nil}} =
             MemoryList.handle(%{"profileId" => "memory-alpha"}, ctx)
    assert Enum.any?(items, &(&1["id"] == id))
    assert {:ok, %{"items" => matches}} =
             MemorySearch.handle(%{"profileId" => "memory-alpha", "query" => "jasmine"}, ctx)
    assert Enum.any?(matches, &(&1["id"] == id))
    assert {:ok, %{"item" => ^item}} =
             MemoryGet.handle(%{"profileId" => "memory-alpha", "id" => id}, ctx)

    assert {:error, {:invalid_request, _}} =
             MemoryDelete.handle(%{"profileId" => "memory-alpha", "id" => id}, ctx)
    assert {:error, {:invalid_request, _}} =
             MemoryDelete.handle(%{"profileId" => "memory-alpha", "id" => id, "confirm" => true}, ctx)
    assert {:error, {:invalid_request, _}} =
             MemoryDelete.handle(%{"profileId" => "memory-alpha", "id" => id, "confirm" => "other"}, ctx)
    assert {:ok, %{"deleted" => true, "id" => ^id}} =
             MemoryDelete.handle(%{"profileId" => "memory-alpha", "id" => id, "confirm" => id}, ctx)
    assert {:error, {:not_found, _}} =
             MemoryGet.handle(%{"profileId" => "memory-alpha", "id" => id}, ctx)
    assert {:ok, %{"items" => []}} =
             MemorySearch.handle(%{"profileId" => "memory-alpha", "query" => "jasmine"}, ctx)
  end

  test "another profile cannot read or delete the exact item id", %{ctx: ctx} do
    assert {:ok, %{"item" => %{"id" => id}}} =
             MemoryAdd.handle(%{"profileId" => "memory-alpha", "text" => "Uses vertical tabs", "kind" => "user"}, ctx)
    assert {:error, {:not_found, _}} =
             MemoryGet.handle(%{"profileId" => "memory-beta", "id" => id}, ctx)
    assert {:error, {:not_found, _}} =
             MemoryDelete.handle(%{"profileId" => "memory-beta", "id" => id, "confirm" => id}, ctx)
    assert {:ok, %{"items" => []}} = MemoryList.handle(%{"profileId" => "memory-beta"}, ctx)
    assert {:ok, %{"item" => _}} =
             MemoryGet.handle(%{"profileId" => "memory-alpha", "id" => id}, ctx)
  end

  test "registry schemas and authorization distinguish reads from admin mutations", %{ctx: ctx} do
    read_ctx = Map.put(ctx, :auth, %{role: :operator, scopes: [:read]})
    admin_ctx = Map.put(ctx, :auth, %{role: :operator, scopes: [:admin]})
    params = %{"profileId" => "memory-alpha", "text" => "Writes concise notes"}
    assert {:error, _} = Registry.dispatch("memory.add", params, read_ctx)
    assert {:ok, %{"item" => item}} = Registry.dispatch("memory.add", params, admin_ctx)
    assert {:ok, %{"items" => _}} = Registry.dispatch("memory.list", %{"profileId" => "memory-alpha"}, read_ctx)
    assert {:error, _} = Registry.dispatch("memory.delete", %{"profileId" => "memory-alpha", "id" => item["id"], "confirm" => item["id"]}, read_ctx)
    assert {:error, _} = Schemas.validate("memory.delete", %{"profileId" => "memory-alpha", "id" => item["id"]})
    assert {:error, _} = Schemas.validate("memory.search", %{"profileId" => "memory-alpha"})
    assert Registry.dispatch_mode("memory.list") == :async
    assert MemoryAdd.scopes() == [:admin]
    assert MemoryDelete.scopes() == [:admin]
    assert MemoryGet.scopes() == [:read]
  end

  test "remote profile dispatch contains only JSON-safe destination-local arguments", %{ctx: ctx} do
    suffix = System.unique_integer([:positive])
    node_id = "memory-node-#{suffix}"
    node_name = "memory-worker-#{suffix}"
    :ok = NodeRegistry.register(node_id, node_name, self())
    on_exit(fn -> NodeRegistry.unregister(node_id, self()) end)
    {:ok, _} = ProfileStore.create(%{"id" => "memory-remote", "node" => node_name})
    params = %{"profileId" => "memory-remote", "query" => "tea", "limit" => 3,
               "cwd" => "/controller/should-not-cross", "callback" => self()}
    task = Task.async(fn -> MemorySearch.handle(params, ctx) end)
    assert_receive {:node_event, "node.invoke.request", payload}, 1_000
    assert payload["nodeId"] == node_id
    assert payload["method"] == "memory.search"
    assert payload["args"] == %{"profileId" => "memory-remote", "query" => "tea", "limit" => 3}
    assert {:ok, _} = LemonCore.JSONPayload.validate(payload["args"])
    assert {:ok, _} = Jason.encode(payload["args"])
    :ok = NodeRegistry.complete(node_id, payload["invokeId"], %{"ok" => true, "payload" => %{"items" => [], "nextCursor" => nil}})
    assert Task.await(task) == {:ok, %{"items" => [], "nextCursor" => nil}}

    get_task = Task.async(fn ->
      MemoryGet.handle(%{"profileId" => "memory-remote", "id" => "remote-record"}, ctx)
    end)
    assert_receive {:node_event, "node.invoke.request", get_payload}, 1_000
    unsafe_item = %{
      "id" => "remote-record", "kind" => "run", "source" => "durable",
      "text" => "password=hunter2 /private/key.pem " <> String.duplicate("é", 2_000),
      "createdAtMs" => 10, "updatedAtMs" => 20, "rawDocument" => "must not cross"
    }
    :ok = NodeRegistry.complete(node_id, get_payload["invokeId"],
      %{"ok" => true, "payload" => %{"item" => unsafe_item, "raw" => "must not cross"}})
    assert {:ok, %{"item" => projected}} = Task.await(get_task)
    assert byte_size(projected["text"]) <= 2_048
    assert String.valid?(projected["text"])
    refute projected["text"] =~ "hunter2"
    refute projected["text"] =~ "/private"
    refute Map.has_key?(projected, "rawDocument")
    :ok = NodeRegistry.unregister(node_id, self())
  end

  test "local explicit memory scope is echoed and exact IDs do not authorize another actor", %{ctx: ctx} do
    a = %{"profileId" => "memory-alpha", "memoryScope" => "private", "memoryContextKey" => "actor-a"}
    b = %{a | "memoryContextKey" => "actor-b"}
    assert {:ok, %{"item" => item, "memoryScope" => "private", "memoryContextKey" => "actor-a"}} =
      MemoryAdd.handle(Map.put(a, "text", "Private actor preference."), ctx)
    assert item["source"] == "durable"
    assert {:ok, %{"items" => [^item], "memoryScope" => "private", "memoryContextKey" => "actor-a"}} =
      MemoryList.handle(a, ctx)
    assert {:ok, %{"items" => []}} = MemoryList.handle(b, ctx)
    assert {:error, {:not_found, _}} = MemoryGet.handle(Map.put(b, "id", item["id"]), ctx)
    assert {:error, {:not_found, _}} = MemoryDelete.handle(
      Map.merge(b, %{"id" => item["id"], "confirm" => item["id"]}), ctx)
    assert {:error, {:invalid_request, _}} = MemoryList.handle(Map.delete(a, "memoryContextKey"), ctx)
    shared = %{"profileId" => "memory-alpha", "memoryScope" => "shared", "memoryContextKey" => nil}
    assert :ok = Schemas.validate("memory.list", shared)
    assert {:ok, %{"items" => [], "memoryScope" => "shared", "memoryContextKey" => nil}} =
      MemoryList.handle(shared, ctx)
    assert {:ok, %{"deleted" => true, "memoryScope" => "private", "memoryContextKey" => "actor-a"}} =
      MemoryDelete.handle(Map.merge(a, %{"id" => item["id"], "confirm" => item["id"]}), ctx)
  end

  test "scoped remote methods refuse old capabilities before any private mutation is enqueued", %{ctx: ctx} do
    suffix = System.unique_integer([:positive])
    node_id = "memory-old-scope-#{suffix}"
    name = "memory-old-scope-worker-#{suffix}"
    :ok = NodeRegistry.register(node_id, name, self(), %{capabilities: %{"memory.add" => %{"version" => 1}}})
    on_exit(fn -> NodeRegistry.unregister(node_id, self()) end)
    {:ok, _} = ProfileStore.create(%{"id" => "memory-old-scoped", "node" => name})
    base = %{"profileId" => "memory-old-scoped", "memoryScope" => "private", "memoryContextKey" => "actor-a"}
    for {handler, extra} <- [{MemoryList, %{}}, {MemorySearch, %{"query" => "tea"}},
      {MemoryGet, %{"id" => "durable_known"}}, {MemoryAdd, %{"text" => "Must remain private."}},
      {MemoryDelete, %{"id" => "durable_known", "confirm" => "durable_known"}}] do
      assert {:error, {:unavailable, _}} = handler.handle(Map.merge(base, extra), ctx)
    end
    refute_receive {:node_event, "node.invoke.request", _}
    :ok = NodeRegistry.unregister(node_id, self())
  end

  test "scoped remote arguments and replies require the same exact context echo", %{ctx: ctx} do
    suffix = System.unique_integer([:positive])
    node_id = "memory-scope-#{suffix}"
    name = "memory-scope-worker-#{suffix}"
    capabilities = Map.new(["memory.list", "memory.search"], &{&1, %{"version" => 1, "contextVersion" => 1}})
    :ok = NodeRegistry.register(node_id, name, self(), %{capabilities: capabilities})
    on_exit(fn -> NodeRegistry.unregister(node_id, self()) end)
    {:ok, _} = ProfileStore.create(%{"id" => "memory-scoped-remote", "node" => name})
    params = %{"profileId" => "memory-scoped-remote", "memoryScope" => "private",
      "memoryContextKey" => "actor-a", "query" => "tea", "limit" => 3}
    for reply <- [%{"items" => [], "nextCursor" => nil},
      %{"items" => [], "nextCursor" => nil, "memoryScope" => "private", "memoryContextKey" => "actor-b"}] do
      task = Task.async(fn -> MemorySearch.handle(Map.put(params, "callback", self()), ctx) end)
      assert_receive {:node_event, "node.invoke.request", payload}, 1_000
      assert payload["nodeId"] == node_id
      assert payload["args"] == params
      assert Jason.decode!(Jason.encode!(payload["args"])) == params
      :ok = NodeRegistry.complete(node_id, payload["invokeId"], %{"ok" => true, "payload" => reply})
      assert {:error, {:unavailable, _}} = Task.await(task)
    end
    task = Task.async(fn -> MemorySearch.handle(params, ctx) end)
    assert_receive {:node_event, "node.invoke.request", payload}, 1_000
    reply = %{"items" => [], "nextCursor" => nil, "memoryScope" => "private", "memoryContextKey" => "actor-a"}
    :ok = NodeRegistry.complete(node_id, payload["invokeId"], %{"ok" => true, "payload" => reply})
    assert Task.await(task) == {:ok, reply}
    shared = %{"profileId" => "memory-scoped-remote", "memoryScope" => "shared", "memoryContextKey" => nil}
    shared_task = Task.async(fn -> MemoryList.handle(shared, ctx) end)
    assert_receive {:node_event, "node.invoke.request", shared_payload}, 1_000
    assert shared_payload["args"] == shared
    shared_reply = Map.merge(shared, %{"items" => [], "nextCursor" => nil}) |> Map.delete("profileId")
    :ok = NodeRegistry.complete(node_id, shared_payload["invokeId"], %{"ok" => true, "payload" => shared_reply})
    assert Task.await(shared_task) == {:ok, shared_reply}
    :ok = NodeRegistry.unregister(node_id, self())
  end

  test "managed RPC search preserves full 512-codepoint Unicode queries", %{ctx: ctx} do
    scope = %{"profileId" => "memory-alpha", "memoryScope" => "private", "memoryContextKey" => "unicode-query"}
    query = String.duplicate("界", 512)
    assert {:ok, %{"item" => item}} = MemoryAdd.handle(Map.put(scope, "text", query), ctx)
    assert {:ok, %{"items" => [^item]}} = MemorySearch.handle(Map.put(scope, "query", query), ctx)
    for invalid <- [query <> "界", String.duplicate("e\u0301", 257), <<255>>] do
      assert {:error, {:invalid_request, _}} =
        MemorySearch.handle(Map.put(scope, "query", invalid), ctx)
    end
  end

  test "lost remote mutation result is not advertised as retry-safe", %{ctx: ctx} do
    suffix = System.unique_integer([:positive])
    node_id = "memory-unknown-#{suffix}"
    node_name = "memory-unknown-worker-#{suffix}"
    :ok = NodeRegistry.register(node_id, node_name, self())
    {:ok, _} = ProfileStore.create(%{"id" => "memory-uncertain", "node" => node_name})
    task = Task.async(fn -> MemoryAdd.handle(%{"profileId" => "memory-uncertain", "text" => "Keeps weekly notes"}, ctx) end)
    assert_receive {:node_event, "node.invoke.request", payload}, 1_000
    :ok = NodeRegistry.complete(node_id, payload["invokeId"], nil, "disconnected")
    assert {:error, {:unavailable, _, details}} = Task.await(task)
    assert details["retrySafe"] == false
    assert details["invokeId"] == payload["invokeId"]
    assert details["code"] == "MEMORY_OUTCOME_UNKNOWN"
    :ok = NodeRegistry.unregister(node_id, self())
  end
end
