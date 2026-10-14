defmodule LemonCore.Secrets.RevisionTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Clock, Secrets, Store}
  alias LemonCore.Store.{EtsBackend, JsonlBackend}

  defmodule TestKey do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :revision_test

    @impl true
    def fetch(opts), do: {:ok, Keyword.fetch!(opts, :test_key)}
  end

  defmodule BlockingKey do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :revision_blocking_test

    @impl true
    def fetch(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:key_fetch, self()})

      receive do
        :continue -> {:ok, Keyword.fetch!(opts, :test_key)}
      end
    end
  end

  # Uses the existing Store backend injection seam and process-local controls.
  defmodule ControlledBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(opts) do
      Process.put({__MODULE__, :test_pid}, Keyword.fetch!(opts, :test_pid))
      EtsBackend.init(opts)
    end

    @impl true
    def put(state, :revision_test_control, :mode, mode) do
      Process.put({__MODULE__, :mode}, mode)
      {:ok, state}
    end

    def put(state, :secrets_v1, key, value) do
      if mode() == :fail_put,
        do: {:error, :injected_put_failure},
        else: EtsBackend.put(state, :secrets_v1, key, value)
    end

    def put(state, table, key, value), do: EtsBackend.put(state, table, key, value)

    @impl true
    defdelegate put_new(state, table, key, value), to: EtsBackend

    @impl true
    def get(state, :secrets_v1, key) do
      if mode() == :observe do
        send(Process.get({__MODULE__, :test_pid}), {:snapshot_read, key})
      end

      if mode() == :fail_read,
        do: {:error, :injected_read_failure},
        else: EtsBackend.get(state, :secrets_v1, key)
    end

    def get(state, table, key), do: EtsBackend.get(state, table, key)

    @impl true
    defdelegate delete(state, table, key), to: EtsBackend

    @impl true
    def compare_and_delete_many(state, entries) do
      if mode() == :fail_delete and Enum.any?(entries, &(elem(&1, 0) == :secrets_v1)),
        do: {:error, :injected_delete_failure, state},
        else: EtsBackend.compare_and_delete_many(state, entries)
    end

    @impl true
    def list(state, :secrets_v1) do
      if mode() == :observe do
        send(Process.get({__MODULE__, :test_pid}), :snapshot_listed)
      end

      if mode() == :fail_list,
        do: {:error, :injected_list_failure},
        else: EtsBackend.list(state, :secrets_v1)
    end

    def list(state, table), do: EtsBackend.list(state, table)

    @impl true
    def compare_and_swap(state, :secrets_v1, key, expected, replacement) do
      case mode() do
        :fail_cas ->
          {:error, :injected_cas_failure, state}

        :usage_race ->
          Process.delete({__MODULE__, :mode})
          {:ok, current, state} = EtsBackend.get(state, :secrets_v1, key)
          touched = Map.update!(current, :usage_count, &(&1 + 1))
          {:ok, state} = EtsBackend.put(state, :secrets_v1, key, touched)
          {:error, :mismatch, state}

        {:replacement_race, record} ->
          Process.delete({__MODULE__, :mode})
          {:ok, state} = EtsBackend.put(state, :secrets_v1, key, record)
          {:error, :mismatch, state}

        _ ->
          {:ok, current, state} = EtsBackend.get(state, :secrets_v1, key)

          if current === expected do
            EtsBackend.put(state, :secrets_v1, key, replacement)
          else
            {:error, :mismatch, state}
          end
      end
    end

    defp mode, do: Process.get({__MODULE__, :mode})
  end

  setup do
    store = :secrets_revision_store
    start_store(store, ControlledBackend, test_pid: self())

    opts = [
      store: store,
      key_providers: [TestKey],
      test_key: Base.encode64(:crypto.strong_rand_bytes(32))
    ]

    {:ok, store: store, opts: opts}
  end

  test "usage reads preserve an outstanding revision and CAS consumes it", ctx do
    assert {:ok, initial} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)

    for _ <- 1..3 do
      assert {:ok, "original"} = Secrets.get("credential", ctx.opts)
      assert {:ok, "original", ^revision} = Secrets.get_with_revision("credential", ctx.opts)
    end

    assert {:ok, [used]} = Secrets.list(ctx.opts)
    assert used.usage_count == 7
    assert used.updated_at == initial.updated_at
    assert {:ok, _} = Secrets.set_if_revision("credential", "refreshed", revision, ctx.opts)

    assert {:error, :stale_revision} =
             Secrets.set_if_revision("credential", "late", revision, ctx.opts)

    assert {:ok, "refreshed"} = Secrets.get("credential", ctx.opts)
  end

  test "owner, name and storage identities cannot reuse another revision", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:ok, entry} = Store.fetch(ctx.store, Secrets.table(), {"default", "credential"})

    other_store = :secrets_revision_other_store
    start_store(other_store, EtsBackend, [])

    for {store, owner, name} <- [
          {ctx.store, "other", "credential"},
          {ctx.store, "default", "other"},
          {other_store, "default", "credential"}
        ] do
      assert :ok = Store.put(store, Secrets.table(), {owner, name}, entry)
      opts = Keyword.merge(ctx.opts, store: store, owner: owner)
      assert {:error, :stale_revision} = Secrets.set_if_revision(name, "late", revision, opts)
      assert {:ok, "original"} = Secrets.get(name, opts)
    end
  end

  test "replacement including identical plaintext invalidates the previous incarnation", ctx do
    for replacement <- ["replacement", "original"] do
      assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
      assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
      assert {:ok, _} = Secrets.set("credential", replacement, ctx.opts)

      assert {:error, :stale_revision} =
               Secrets.set_if_revision("credential", "late", revision, ctx.opts)

      assert {:ok, ^replacement} = Secrets.get("credential", ctx.opts)
    end
  end

  test "deletion and identical delete-recreate cannot resurrect a stale refresh", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    assert :ok = Secrets.delete("credential", ctx.opts)

    assert {:error, :stale_revision} =
             Secrets.set_if_revision("credential", "late", revision, ctx.opts)

    assert {:error, :not_found} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)

    assert {:error, :stale_revision} =
             Secrets.set_if_revision("credential", "late", revision, ctx.opts)

    assert {:ok, "original"} = Secrets.get("credential", ctx.opts)
  end

  test "two refresh writers sharing a revision have exactly one winner", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    parent = self()

    tasks =
      for value <- ["first", "second"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :continue -> Secrets.set_if_revision("credential", value, revision, ctx.opts)
          end
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, pid}
      send(pid, :continue)
    end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 1
  end

  test "an exact-record CAS usage race retries only the original incarnation", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    control(ctx.store, :usage_race)
    assert {:ok, _} = Secrets.set_if_revision("credential", "refreshed", revision, ctx.opts)
    assert {:ok, "refreshed"} = Secrets.get("credential", ctx.opts)
  end

  test "a replacement at the atomic CAS boundary is never overwritten", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:ok, _} = Secrets.set("replacement", "new-login", ctx.opts)

    assert {:ok, replacement} =
             Store.fetch(ctx.store, Secrets.table(), {"default", "replacement"})

    control(ctx.store, {:replacement_race, replacement})

    assert {:error, :stale_revision} =
             Secrets.set_if_revision("credential", "late", revision, ctx.opts)

    assert {:ok, "new-login"} = Secrets.get("credential", ctx.opts)
  end

  test "usage reads remain available while a replacement holds the mutation lease", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    writer = blocked_writer(ctx)
    assert {:ok, "original", ^revision} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:ok, "original"} = Secrets.get("credential", ctx.opts)
    send(writer.pid, :continue)
    assert {:ok, _} = Task.await(writer)

    assert {:error, :stale_revision} =
             Secrets.set_if_revision("credential", "late", revision, ctx.opts)

    assert {:ok, "new-login"} = Secrets.get("credential", ctx.opts)
  end

  test "a queued deletion cannot erase the writer holding the shared mutation lease", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    writer = blocked_writer(ctx)
    control(ctx.store, :observe)
    deletion = Task.async(fn -> Secrets.delete("credential", ctx.opts) end)
    assert_receive {:snapshot_read, {"default", "credential"}}
    send(writer.pid, :continue)
    assert {:ok, _} = Task.await(writer)
    assert {:error, :stale_revision} = Task.await(deletion)
    assert {:ok, "new-login"} = Secrets.get("credential", ctx.opts)
  end

  test "expired-list cleanup cannot remove a replacement of its snapshot", ctx do
    assert {:ok, _} =
             Secrets.set("credential", "expired", [expires_at: Clock.now_ms() - 1] ++ ctx.opts)

    writer = blocked_writer(ctx)
    control(ctx.store, :observe)
    listing = Task.async(fn -> Secrets.list(ctx.opts) end)
    assert_receive :snapshot_listed
    send(writer.pid, :continue)
    assert {:ok, _} = Task.await(writer)
    assert {:ok, []} = Task.await(listing)
    assert {:ok, "new-login"} = Secrets.get("credential", ctx.opts)
  end

  test "reads do not remove expired records", ctx do
    assert {:ok, _} =
             Secrets.set("credential", "expired", [expires_at: Clock.now_ms() - 1] ++ ctx.opts)

    assert {:ok, before_read} = Store.fetch(ctx.store, Secrets.table(), {"default", "credential"})
    assert {:error, :expired} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:error, :expired} = Secrets.get("credential", ctx.opts)

    assert {:ok, ^before_read} =
             Store.fetch(ctx.store, Secrets.table(), {"default", "credential"})

    assert {:error, :stale_revision} =
             Secrets.set_if_revision("credential", "late", "invalid", ctx.opts)
  end

  test "legacy reads add only usage metadata and retain their revision", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, entry} = Store.fetch(ctx.store, Secrets.table(), {"default", "credential"})
    legacy = Map.delete(entry, :incarnation)
    assert :ok = Store.put(ctx.store, Secrets.table(), {"default", "credential"}, legacy)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:ok, "original", ^revision} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:ok, touched} = Store.fetch(ctx.store, Secrets.table(), {"default", "credential"})

    assert Map.drop(touched, [:usage_count, :last_used_at]) ==
             Map.drop(legacy, [:usage_count, :last_used_at])

    assert {:ok, _} = Secrets.set_if_revision("credential", "refreshed", revision, ctx.opts)
  end

  test "strict reads and writes preserve backend read failures", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    control(ctx.store, :fail_read)
    assert {:error, :store_unavailable} = Secrets.get("credential", ctx.opts)
    assert {:error, :store_unavailable} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:error, :store_unavailable} = Secrets.set("credential", "new-login", ctx.opts)

    assert {:error, :store_unavailable} =
             Secrets.set_if_revision("credential", "late", revision, ctx.opts)

    assert {:error, :store_unavailable} = Secrets.delete("credential", ctx.opts)
    control(ctx.store, nil)
    assert {:ok, "original"} = Secrets.get("credential", ctx.opts)
  end

  test "put and CAS failures never acknowledge a credential save", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    control(ctx.store, :fail_put)
    assert {:error, :injected_put_failure} = Secrets.set("credential", "new-login", ctx.opts)
    control(ctx.store, :fail_cas)

    assert {:error, :injected_cas_failure} =
             Secrets.set_if_revision("credential", "late", revision, ctx.opts)

    control(ctx.store, nil)
    assert {:ok, "original", ^revision} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:ok, _} = Secrets.set_if_revision("credential", "refreshed", revision, ctx.opts)
  end

  test "usage-touch failure is best effort without changing the revision", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", ctx.opts)
    assert {:ok, before_read} = Store.fetch(ctx.store, Secrets.table(), {"default", "credential"})
    control(ctx.store, :fail_cas)
    assert {:ok, "original", ^revision} = Secrets.get_with_revision("credential", ctx.opts)

    assert {:ok, ^before_read} =
             Store.fetch(ctx.store, Secrets.table(), {"default", "credential"})
  end

  test "delete, expiry cleanup and list failures propagate without false success", ctx do
    assert {:ok, _} = Secrets.set("credential", "original", ctx.opts)

    assert {:ok, _} =
             Secrets.set("expired", "expired", [expires_at: Clock.now_ms() - 1] ++ ctx.opts)

    control(ctx.store, :fail_delete)
    assert {:error, _} = Secrets.delete("credential", ctx.opts)
    assert {:error, _} = Secrets.list(ctx.opts)
    control(ctx.store, :fail_list)
    assert {:error, :store_unavailable} = Secrets.list(ctx.opts)
    assert {:error, :store_unavailable} = Secrets.status(ctx.opts)
    control(ctx.store, nil)
    assert {:ok, "original"} = Secrets.get("credential", ctx.opts)
    assert {:ok, expired} = Store.fetch(ctx.store, Secrets.table(), {"default", "expired"})
    assert is_map(expired)
  end

  test "an unavailable Store is not reported as a missing credential", ctx do
    opts = Keyword.put(ctx.opts, :store, :secrets_revision_absent_store)
    assert {:error, :store_unavailable} = Secrets.get_with_revision("credential", opts)
    assert {:error, :store_unavailable} = Secrets.set("credential", "new-login", opts)

    assert {:error, :store_unavailable} =
             Secrets.set_if_revision("credential", "late", "invalid", opts)

    assert {:error, :store_unavailable} = Secrets.delete("credential", opts)
    assert {:error, :store_unavailable} = Secrets.list(opts)
  end

  test "a durable storage restart rejects the pre-restart revision", ctx do
    path = temporary_store_path()
    store = :secrets_revision_durable_store
    start_store(store, JsonlBackend, path: path)
    opts = Keyword.put(ctx.opts, :store, store)
    assert {:ok, _} = Secrets.set("credential", "original", opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", opts)
    assert :ok = stop_supervised(store)
    start_store(store, JsonlBackend, path: path)
    assert {:ok, "original", current_revision} = Secrets.get_with_revision("credential", opts)
    refute current_revision == revision

    assert {:error, :stale_revision} =
             Secrets.set_if_revision("credential", "late", revision, opts)

    assert {:ok, _} = Secrets.set_if_revision("credential", "refreshed", current_revision, opts)
  end

  test "an actual JSONL append failure cannot acknowledge or durably replace a refresh", ctx do
    path = temporary_store_path()
    store = :secrets_revision_append_failure_store
    start_store(store, JsonlBackend, [path: path], restart: :temporary)
    opts = Keyword.put(ctx.opts, :store, store)
    assert {:ok, _} = Secrets.set("credential", "original", opts)
    assert {:ok, "original", revision} = Secrets.get_with_revision("credential", opts)
    wal = Path.join(path, "secrets_v1.jsonl")
    saved_wal = wal <> ".saved"
    assert :ok = File.rename(wal, saved_wal)
    assert :ok = File.mkdir(wal)

    assert {:error, _reason} =
             Secrets.set_if_revision("credential", "late", revision, opts)

    assert {:ok, "original", ^revision} = Secrets.get_with_revision("credential", opts)
    assert :ok = File.rmdir(wal)
    assert :ok = File.rename(saved_wal, wal)
    assert stop_supervised(store) in [:ok, {:error, :not_found}]
    start_store(store, JsonlBackend, path: path)
    assert {:ok, "original"} = Secrets.get("credential", opts)
    assert {:ok, _} = Secrets.set("credential", "recovered-login", opts)
    assert {:ok, "recovered-login"} = Secrets.get("credential", opts)
  end

  defp blocked_writer(ctx) do
    opts = Keyword.merge(ctx.opts, key_providers: [BlockingKey], test_pid: self())
    writer = Task.async(fn -> Secrets.set("credential", "new-login", opts) end)
    assert_receive {:key_fetch, pid}
    assert pid == writer.pid
    writer
  end

  defp control(store, mode) do
    assert :ok = Store.put(store, :revision_test_control, :mode, mode)
  end

  defp start_store(name, backend, backend_opts, child_opts \\ []) do
    spec =
      Supervisor.child_spec(
        {Store, name: name, backend: backend, backend_opts: backend_opts, cached_tables: []},
        Keyword.merge([id: name], child_opts)
      )

    start_supervised!(spec)
  end

  defp temporary_store_path do
    path = Path.join(System.tmp_dir!(), "secrets-revision-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
