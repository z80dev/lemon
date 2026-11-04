defmodule LemonCore.AgentIdentityTest do
  use ExUnit.Case, async: false

  alias LemonCore.{AgentIdentity, AgentMessaging, RunStore, SessionLifecycle, Store}
  alias LemonCore.Store.JsonlBackend

  defmodule FailingBackend do
    @behaviour LemonCore.Store.Backend

    def init(_opts), do: {:ok, %{}}
    def put(_state, _table, _key, _value), do: {:error, :sqlite_busy}
    def put_new(_state, _table, _key, _value), do: {:error, :sqlite_busy}
    def compare_and_swap(_state, _table, _key, _expected, _value), do: {:error, :sqlite_busy}
    def delete(_state, _table, _key), do: {:error, :sqlite_busy}
    def list(_state, _table), do: {:error, :sqlite_busy}

    def get(%{mode: :read}, _table, _key), do: {:error, :sqlite_busy}

    def get(state, table, key) do
      case state.backend.get(state.backend_state, table, key) do
        {:ok, value, backend_state} -> {:ok, value, %{state | backend_state: backend_state}}
        {:error, _} = error -> error
      end
    end
  end

  # Inject one concurrent backend mutation at the exact CAS boundary. The real
  # public operation must handle the resulting mismatch/retry itself.
  defmodule RacingBackend do
    @behaviour LemonCore.Store.Backend

    defdelegate init(opts), to: JsonlBackend
    defdelegate get(state, table, key), to: JsonlBackend
    defdelegate put_new(state, table, key, value), to: JsonlBackend
    defdelegate delete(state, table, key), to: JsonlBackend
    defdelegate list(state, table), to: JsonlBackend
    defdelegate sync(state), to: JsonlBackend

    def put(state, :identity_test_control, :race, race) do
      Process.put({__MODULE__, :race}, race)
      {:ok, state}
    end

    def put(state, table, key, value), do: JsonlBackend.put(state, table, key, value)

    def compare_and_swap(state, table, key, expected, replacement) do
      case Process.get({__MODULE__, :race}) do
        {^table, ^key, mutate} ->
          Process.delete({__MODULE__, :race})
          {:ok, state} = mutate.(state)
          {:error, :mismatch, state}

        _ ->
          with {:ok, current, state} <- JsonlBackend.get(state, table, key) do
            if current === expected,
              do: JsonlBackend.put(state, table, key, replacement),
              else: {:error, :mismatch, state}
          end
      end
    end
  end

  defmodule BrokenRuntime do
    @behaviour LemonCore.AgentMessaging

    def list(_scope, _opts), do: raise("private query failure")
    def rename(_scope, _id, _name), do: :ok

    def send(_scope, _source, _target, _text, _opts) do
      Kernel.send(self(), :runtime_applied_before_failure)
      raise "private mutation failure"
    end

    def get(_scope, _source, _message_id), do: exit(:noproc)
    def register_external(_scope, _attrs, _pid), do: throw(:private_failure)
    def unregister_external(_scope, _id, _pid), do: nil
    def complete_external(_pid, _message_id, _completion), do: raise("private mutation failure")
  end

  setup do
    assert {:ok, _} = Application.ensure_all_started(:lemon_core)
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    scope = "bot:identity-test:#{suffix}"
    on_exit(fn -> Store.delete(:agent_identities_v1, scope) end)
    {:ok, scope: scope, suffix: suffix}
  end

  test "concurrent duplicate claims have exactly one winner", %{scope: scope} do
    parent = self()

    tasks =
      for number <- 1..32 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :claim -> AgentIdentity.register(scope, "bot://concurrent/#{number}", %{name: "@BoB"})
          end
        end)
      end

    Enum.each(tasks, fn task -> assert_receive {:ready, pid} when pid == task.pid end)
    Enum.each(tasks, fn task -> send(task.pid, :claim) end)
    results = Enum.map(tasks, &Task.await/1)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, :name_taken})) == 31
    assert winner.name == "bob"
    assert {:ok, ^winner} = AgentIdentity.resolve(scope, "@BOB")
    assert {:ok, [^winner]} = AgentIdentity.list(scope)
  end

  test "rename is atomic, preserves stable IDs and releases only its own binding", %{scope: scope} do
    first = "bot://rename/first"
    second = "bot://rename/second"
    assert {:ok, _} = AgentIdentity.register(scope, first, %{name: "bob", label: "First"})
    assert {:ok, _} = AgentIdentity.register(scope, second, %{name: "alice"})

    assert {:error, :name_taken} = AgentIdentity.rename(scope, first, "@ALICE")
    assert {:ok, %{id: ^first, name: "bob"}} = AgentIdentity.resolve(scope, "bob")

    assert {:ok, renamed} = AgentIdentity.rename(scope, first, "@Robert")
    assert renamed.id == first
    assert renamed.name == "robert"
    assert renamed.label == "First"
    assert {:ok, ^renamed} = AgentIdentity.rename(scope, first, "ROBERT")
    assert {:ok, ^renamed} = AgentIdentity.resolve(scope, first)
    assert {:error, :not_found} = AgentIdentity.resolve(scope, "bob")

    assert {:ok, %{name: "bob"}} = AgentIdentity.rename(scope, second, "bob")
    assert :ok = AgentIdentity.remove(scope, first)
    assert {:ok, %{id: ^second}} = AgentIdentity.resolve(scope, "bob")
    assert {:error, :not_found} = AgentIdentity.resolve(scope, "robert")
  end

  test "clearing and deleting handles never leave a stale name target", %{scope: scope} do
    id = "bot://clear/first"
    assert {:ok, _} = AgentIdentity.register(scope, id, %{name: "bob"})
    assert {:ok, %{id: ^id, name: nil}} = AgentIdentity.rename(scope, id, nil)
    assert {:error, :not_found} = AgentIdentity.resolve(scope, "@bob")
    assert {:ok, %{id: ^id, name: nil}} = AgentIdentity.resolve(scope, id)
    assert {:ok, _} = AgentIdentity.register(scope, "bot://clear/second", %{name: "bob"})
    assert :ok = AgentIdentity.remove(scope, id)
    assert {:error, :not_found} = AgentIdentity.resolve(scope, id)
    assert {:ok, %{id: "bot://clear/second"}} = AgentIdentity.resolve(scope, "bob")
  end

  test "private scopes never resolve or enumerate another scope", %{scope: scope, suffix: suffix} do
    other = "bot:identity-other:#{suffix}"
    operator_id = "bot://scope/operator-#{suffix}"

    on_exit(fn ->
      Store.delete(:agent_identities_v1, other)
      AgentIdentity.remove("operator", operator_id)
    end)

    assert {:ok, _} =
             AgentIdentity.register("operator", operator_id, %{name: "operator_#{suffix}"})

    assert {:ok, _} = AgentIdentity.register(scope, "bot://scope/first", %{name: "bob"})
    assert {:ok, _} = AgentIdentity.register(other, "bot://scope/second", %{name: "bob"})
    assert {:ok, [%{id: "bot://scope/first"}]} = AgentIdentity.list(scope)
    assert {:ok, %{id: "bot://scope/first"}} = AgentIdentity.resolve(scope, "bob")
    assert {:ok, %{id: "bot://scope/second"}} = AgentIdentity.resolve(other, "bob")
    assert {:error, :not_found} = AgentIdentity.resolve(scope, "bot://scope/second")
    assert {:error, :not_found} = AgentIdentity.resolve(scope, operator_id)
    assert {:error, :not_found} = AgentIdentity.resolve("operator", "bot://scope/first")
  end

  test "native registration requires a canonical existing session and stale sessions stop resolving",
       %{scope: scope, suffix: suffix} do
    key = "agent:identity_#{suffix}:main"
    id = "session://" <> key
    name = "native_#{suffix}"

    on_exit(fn ->
      AgentIdentity.remove("operator", id)
      RunStore.delete_session_index(key)
    end)

    assert {:error, :not_found} = AgentIdentity.register("operator", id, %{name: name})

    assert {:error, :invalid_id} =
             AgentIdentity.register("operator", "session://agent::main", %{})

    assert :ok = RunStore.create_session_index(key, "identity_#{suffix}", :control_plane)
    assert {:error, :invalid_scope} = AgentIdentity.register(scope, id, %{name: name})
    assert {:ok, entry} = AgentIdentity.register("operator", id, %{name: name})
    assert entry.session_key == key
    assert entry.kind == :session
    assert :ok = RunStore.delete_session_index(key)
    assert {:error, :not_found} = AgentIdentity.resolve("operator", id)
    assert {:error, :not_found} = AgentIdentity.resolve("operator", name)
    assert {:error, :not_found} = AgentIdentity.rename("operator", id, "changed")
    assert {:ok, []} = AgentIdentity.list("operator", query: name)
  end

  test "deletion fences a pending claim and its retries cannot claim a replacement",
       %{suffix: suffix} do
    path = Path.join(System.tmp_dir!(), "agent_identity_fence_#{suffix}")
    on_exit(fn -> File.rm_rf!(path) end)
    assert {:ok, backend_state} = JsonlBackend.init(path: path)

    with_backend(RacingBackend, backend_state, fn ->
      key = "agent:identity_fence_#{suffix}:main"
      on_exit(fn -> RunStore.delete_session_index(key) end)
      id = "session://" <> key
      assert :ok = RunStore.create_session_index(key, "identity_fence_#{suffix}", :control_plane)
      assert {:ok, original} = RunStore.ensure_session_incarnation(key)
      assert {:ok, nil} = Store.fetch(:agent_identities_v1, "operator")

      assert :ok =
               Store.put(:identity_test_control, :race, {:agent_identities_v1, "operator",
                fn state ->
                  # Another writer deleted the session and fenced the absent
                  # identity scope, then recreated the same key/timestamp.
                  {:ok, state} = JsonlBackend.delete(state, :sessions_index, key)
                  replacement = %{original | incarnation: fresh_token()}
                  {:ok, state} = JsonlBackend.put(state, :sessions_index, key, replacement)
                  :ok = LemonCore.Store.ReadCache.delete(Store, :sessions_index, key)

                  JsonlBackend.put(state, :agent_identities_v1, "operator", %{
                    version: 1,
                    revision: fresh_token(),
                    entries: %{},
                    names: %{}
                  })
                end})

      assert {:error, :not_found} = AgentIdentity.register("operator", id, %{name: "bob"})
      assert {:error, :not_found} = AgentIdentity.resolve("operator", "bob")
      assert {:ok, replacement} = RunStore.ensure_session_incarnation(key)
      refute replacement.incarnation == original.incarnation
      assert replacement.created_at_ms == original.created_at_ms
      assert {:ok, %{name: nil, incarnation: token}} = AgentIdentity.register("operator", id, %{})
      assert token == replacement.incarnation
    end)
  end

  test "lifecycle deletion fences an absent scope even without an identity entry",
       %{suffix: suffix} do
    path = Path.join(System.tmp_dir!(), "agent_identity_absent_#{suffix}")
    on_exit(fn -> File.rm_rf!(path) end)
    assert {:ok, backend_state} = JsonlBackend.init(path: path)

    with_backend(JsonlBackend, backend_state, fn ->
      key = "agent:identity_absent_#{suffix}:main"
      assert :ok = RunStore.create_session_index(key, "identity_absent_#{suffix}", :control_plane)
      assert {:ok, nil = snapshot} = Store.fetch(:agent_identities_v1, "operator")
      assert {:ok, %{verified: true}} = SessionLifecycle.delete(key)

      assert {:error, :mismatch} =
               Store.compare_and_swap(:agent_identities_v1, "operator", snapshot, snapshot)
    end)
  end

  test "recreated sessions neither resolve nor inherit stale handles", %{suffix: suffix} do
    key = "agent:identity_recreated_#{suffix}:main"
    id = "session://" <> key
    name = "stale_#{suffix}"
    other = "bot://stale/reclaimer-#{suffix}"

    on_exit(fn ->
      AgentIdentity.remove("operator", id)
      AgentIdentity.remove("operator", other)
      RunStore.delete_session_index(key)
    end)

    assert :ok =
             RunStore.create_session_index(key, "identity_recreated_#{suffix}", :control_plane)

    assert {:ok, original} = AgentIdentity.register("operator", id, %{name: name, label: "Old"})
    assert :ok = RunStore.delete_session_index(key)

    assert :ok =
             RunStore.create_session_index(key, "identity_recreated_#{suffix}", :control_plane)

    assert {:error, :not_found} = AgentIdentity.resolve("operator", name)
    assert {:error, :not_found} = AgentIdentity.resolve("operator", id)
    assert {:error, :not_found} = AgentIdentity.rename("operator", id, "renamed")
    assert {:ok, []} = AgentIdentity.list("operator", query: name)
    assert {:ok, %{name: ^name}} = AgentIdentity.register("operator", other, %{name: name})

    assert {:ok, %{name: nil, label: "", incarnation: incarnation}} =
             AgentIdentity.register("operator", id, %{})

    refute incarnation == original.incarnation
    assert {:ok, %{id: ^other}} = AgentIdentity.resolve("operator", name)
  end

  test "legacy backfill racing deletion never resurrects the missing index", %{suffix: suffix} do
    path = Path.join(System.tmp_dir!(), "agent_identity_backfill_#{suffix}")
    on_exit(fn -> File.rm_rf!(path) end)
    assert {:ok, backend_state} = JsonlBackend.init(path: path)

    with_backend(RacingBackend, backend_state, fn ->
      key = "agent:identity_backfill_#{suffix}:main"
      assert :ok = Store.put(:sessions_index, key, %{session_key: key, created_at_ms: 1})

      assert :ok =
               Store.put(
                 :identity_test_control,
                 :race,
                 {:sessions_index, key,
                  fn state -> JsonlBackend.delete(state, :sessions_index, key) end}
               )

      assert {:error, :not_found} = RunStore.ensure_session_incarnation(key)
      assert {:ok, nil} = RunStore.fetch_session_index(key)
    end)
  end

  test "legacy backfill retries updates once and persists its native binding across reopen",
       %{suffix: suffix} do
    path = Path.join(System.tmp_dir!(), "agent_identity_native_durable_#{suffix}")
    on_exit(fn -> File.rm_rf!(path) end)
    assert {:ok, backend_state} = JsonlBackend.init(path: path)

    with_backend(RacingBackend, backend_state, fn ->
      key = "agent:identity_durable_#{suffix}:main"
      on_exit(fn -> RunStore.delete_session_index(key) end)
      id = "session://" <> key
      legacy = %{session_key: key, created_at_ms: 1, run_count: 0}
      assert :ok = Store.put(:sessions_index, key, legacy)

      assert :ok =
               Store.put(
                 :identity_test_control,
                 :race,
                 {:sessions_index, key,
                  fn state ->
                    JsonlBackend.put(state, :sessions_index, key, %{legacy | run_count: 1})
                  end}
               )

      assert {:ok, %{run_count: 1} = index} = RunStore.ensure_session_incarnation(key)
      assert byte_size(index.incarnation) == 22
      assert {:ok, ^index} = RunStore.ensure_session_incarnation(key)
      assert {:ok, entry} = AgentIdentity.register("operator", id, %{name: "durable_#{suffix}"})
      assert entry.incarnation == index.incarnation
      assert :ok = Store.sync()
      assert {:ok, reopened} = JsonlBackend.init(path: path)

      :sys.replace_state(Store, fn state ->
        :ok = LemonCore.Store.ReadCache.delete(state.read_cache, :sessions_index, key)
        %{state | backend_state: reopened}
      end)

      assert {:ok, ^index} = RunStore.ensure_session_incarnation(key)
      assert {:ok, ^entry} = AgentIdentity.resolve("operator", entry.name)
      assert {:ok, ^entry} = AgentIdentity.rename("operator", id, entry.name)
    end)
  end

  test "a pending rename cannot rename a replacement after its CAS retries", %{suffix: suffix} do
    path = Path.join(System.tmp_dir!(), "agent_identity_rename_race_#{suffix}")
    on_exit(fn -> File.rm_rf!(path) end)
    assert {:ok, backend_state} = JsonlBackend.init(path: path)

    with_backend(RacingBackend, backend_state, fn ->
      key = "agent:identity_rename_race_#{suffix}:main"
      id = "session://" <> key
      on_exit(fn -> RunStore.delete_session_index(key) end)
      assert :ok = RunStore.create_session_index(key, "identity_rename_race_#{suffix}", :tui)
      assert {:ok, index} = RunStore.ensure_session_incarnation(key)
      assert {:ok, original} = AgentIdentity.register("operator", id, %{name: "original"})
      assert {:ok, scope} = Store.fetch(:agent_identities_v1, "operator")
      replacement = %{original | incarnation: fresh_token(), name: "replacement"}

      assert :ok =
               Store.put(
                 :identity_test_control,
                 :race,
                 {:agent_identities_v1, "operator",
                  fn state ->
                    {:ok, state} =
                      JsonlBackend.put(state, :sessions_index, key, %{
                        index
                        | incarnation: replacement.incarnation
                      })

                    :ok = LemonCore.Store.ReadCache.delete(Store, :sessions_index, key)

                    JsonlBackend.put(state, :agent_identities_v1, "operator", %{
                      scope
                      | revision: fresh_token(),
                        entries: %{id => replacement},
                        names: %{"replacement" => id}
                    })
                  end}
               )

      assert {:error, :not_found} = AgentIdentity.rename("operator", id, "stale_rename")
      assert {:ok, ^replacement} = AgentIdentity.resolve("operator", "replacement")
      assert {:error, :not_found} = AgentIdentity.resolve("operator", "stale_rename")
    end)
  end

  test "incarnation backfill fails closed on read, write and malformed index failures",
       %{suffix: suffix} do
    key = "agent:identity_incarnation_failure_#{suffix}:main"
    on_exit(fn -> RunStore.delete_session_index(key) end)
    legacy = %{session_key: key, created_at_ms: 1}
    assert :ok = Store.put(:sessions_index, key, legacy)
    owner = :sys.get_state(Store)

    with_backend(
      FailingBackend,
      %{mode: :write, backend: owner.backend, backend_state: owner.backend_state},
      fn ->
        assert {:error, :store_unavailable} = RunStore.ensure_session_incarnation(key)
      end
    )

    assert {:ok, ^legacy} = RunStore.fetch_session_index(key)

    with_backend(FailingBackend, %{mode: :read}, fn ->
      :sys.replace_state(Store, fn state ->
        :ok = LemonCore.Store.ReadCache.delete(state.read_cache, :sessions_index, key)
        state
      end)

      assert {:error, :store_unavailable} = RunStore.ensure_session_incarnation(key)
    end)

    assert :ok =
             Store.put(
               :sessions_index,
               key,
               %{legacy | created_at_ms: 2} |> Map.put(:incarnation, nil)
             )

    assert {:error, :invalid_session} = RunStore.ensure_session_incarnation(key)
    assert :ok = RunStore.delete_session_index(key)
    assert {:error, :not_found} = RunStore.ensure_session_incarnation(key)
  end

  test "partial registration preserves a handle while explicit nil clears it", %{scope: scope} do
    id = "bot://register/first"

    assert {:ok, _} =
             AgentIdentity.register(scope, id, %{name: "bob", metadata: %{bot_id: "first"}})

    assert {:ok, %{name: "bob", label: "Renamed", metadata: %{bot_id: "first"}}} =
             AgentIdentity.register(scope, id, %{label: "Renamed"})

    assert {:ok, %{name: nil}} = AgentIdentity.register(scope, id, %{name: nil})
    assert {:error, :not_found} = AgentIdentity.resolve(scope, "bob")
  end

  test "external identity and renamed name survive reopening the durable backend", %{
    scope: scope,
    suffix: suffix
  } do
    path = Path.join(System.tmp_dir!(), "agent_identity_#{suffix}")
    on_exit(fn -> File.rm_rf!(path) end)
    assert {:ok, backend_state} = JsonlBackend.init(path: path)

    with_backend(JsonlBackend, backend_state, fn ->
      id = "bot://durable/first"

      assert {:ok, _} =
               AgentIdentity.register(scope, id, %{name: "bob", metadata: %{bot_id: "first"}})

      assert {:ok, renamed} = AgentIdentity.rename(scope, id, "robert")
      assert :ok = Store.sync()
      assert {:ok, reopened} = JsonlBackend.init(path: path)
      :sys.replace_state(Store, fn state -> %{state | backend_state: reopened} end)

      assert {:ok, ^renamed} = AgentIdentity.resolve(scope, "@Robert")
      assert {:ok, ^renamed} = AgentIdentity.resolve(scope, id)
      assert {:ok, [^renamed]} = AgentIdentity.list(scope)
      assert {:error, :not_found} = AgentIdentity.resolve(scope, "bob")
    end)
  end

  test "strict read and CAS write failures stay unavailable and preserve previous binding", %{
    scope: scope
  } do
    id = "bot://failure/first"
    assert {:ok, original} = AgentIdentity.register(scope, id, %{name: "bob"})
    owner = :sys.get_state(Store)

    for mode <- [:read, :write] do
      with_backend(
        FailingBackend,
        %{mode: mode, backend: owner.backend, backend_state: owner.backend_state},
        fn ->
          if mode == :read do
            assert {:error, :store_unavailable} = AgentIdentity.resolve(scope, "bob")
            assert {:error, :store_unavailable} = AgentIdentity.list(scope)
          end

          assert {:error, :store_unavailable} = AgentIdentity.rename(scope, id, "robert")
          assert {:error, :store_unavailable} = AgentIdentity.remove(scope, id)

          assert {:error, :store_unavailable} =
                   AgentIdentity.register(scope, "bot://failure/second", %{name: "alice"})
        end
      )
    end

    assert {:ok, ^original} = AgentIdentity.resolve(scope, "bob")
    assert {:error, :not_found} = AgentIdentity.resolve(scope, "robert")
  end

  test "invalid names and oversized records do not mutate an existing identity", %{scope: scope} do
    id = "bot://validation/first"
    assert {:ok, entry} = AgentIdentity.register(scope, id, %{name: "bob"})

    for name <- ["", "@@bob", "1bob", " bob", "bób", String.duplicate("b", 65)] do
      assert {:error, :invalid_name} = AgentIdentity.rename(scope, id, name)
    end

    assert {:error, :invalid_label} =
             AgentIdentity.register(scope, id, %{label: String.duplicate("l", 257)})

    assert {:error, :invalid_metadata} =
             AgentIdentity.register(scope, id, %{metadata: %{bot_id: String.duplicate("b", 257)}})

    assert {:ok, ^entry} = AgentIdentity.resolve(scope, id)
  end

  test "an unavailable runtime never invents a roster, rename or accepted message", %{
    scope: scope
  } do
    previous = Application.get_env(:lemon_core, :agent_messaging_runtime)
    on_exit(fn -> AgentMessaging.configure(previous) end)
    assert :ok = AgentMessaging.configure(nil)
    assert {:error, :unavailable} = AgentMessaging.list(scope)
    assert {:error, :unavailable} = AgentMessaging.rename(scope, "bot://offline/first", "bob")

    assert {:error, :unavailable} =
             AgentMessaging.send(scope, "bot://offline/first", "@bob", "hello",
               message_id: "offline-message"
             )

    assert {:error, :unavailable} =
             AgentMessaging.get(scope, "bot://offline/first", "offline-message")
  end

  test "runtime failures preserve unknown mutations and unavailable queries", %{scope: scope} do
    previous = Application.get_env(:lemon_core, :agent_messaging_runtime)
    on_exit(fn -> AgentMessaging.configure(previous) end)
    assert :ok = AgentMessaging.configure(BrokenRuntime)

    assert {:error, :query_failed} = AgentMessaging.list(scope)
    assert {:error, :unavailable} = AgentMessaging.get(scope, "bot://runtime/first", "message")
    assert {:error, :outcome_unknown} = AgentMessaging.rename(scope, "bot://runtime/first", "bob")

    assert {:error, :outcome_unknown} =
             AgentMessaging.send(scope, "bot://runtime/first", "@bob", "hello",
               message_id: "message"
             )

    assert_receive :runtime_applied_before_failure
    assert {:error, :outcome_unknown} = AgentMessaging.register_external(scope, %{}, self())

    assert {:error, :outcome_unknown} =
             AgentMessaging.unregister_external(scope, "bot://runtime/first", self())

    assert {:error, :outcome_unknown} = AgentMessaging.complete_external(self(), "message", %{})
  end

  defp fresh_token, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp with_backend(backend, backend_state, fun) do
    previous = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      Process.delete({RacingBackend, :race})
      %{state | backend: backend, backend_state: backend_state}
    end)

    try do
      fun.()
    after
      :sys.replace_state(Store, fn _state ->
        Process.delete({RacingBackend, :race})
        previous
      end)
    end
  end
end
