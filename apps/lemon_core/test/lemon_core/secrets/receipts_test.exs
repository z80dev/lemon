defmodule LemonCore.Secrets.ReceiptsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Clock
  alias LemonCore.Secrets
  alias LemonCore.Secrets.Receipts
  alias LemonCore.Store
  alias LemonCore.Store.JsonlBackend

  @moduletag :tmp_dir

  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_), do: {:ok, %{data: %{}, fault: nil, test_pid: nil}}

    @impl true
    def put(%{fault: :write}, :secrets_v1, _, _), do: {:error, :injected_write_failure}

    def put(state, :secrets_v1 = table, key, value) do
      if state.test_pid do
        send(state.test_pid, {:vault_put, self(), key, value})

        if state.fault == :pause do
          receive do
            :continue -> :ok
          end
        end
      end

      {:ok, %{state | data: Map.put(state.data, {table, key}, value)}}
    end

    def put(state, table, key, value),
      do: {:ok, %{state | data: Map.put(state.data, {table, key}, value)}}

    @impl true
    def put_new(state, table, key, value) do
      if Map.has_key?(state.data, {table, key}),
        do: {:exists, state},
        else: put(state, table, key, value)
    end

    @impl true
    def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

    @impl true
    def delete(state, table, key),
      do: {:ok, %{state | data: Map.delete(state.data, {table, key})}}

    @impl true
    def list(%{fault: :read}, :secrets_v1), do: {:error, :injected_read_failure}

    def list(state, table),
      do: {:ok, for({{^table, key}, value} <- state.data, do: {key, value}), state}
  end

  setup %{tmp_dir: dir} do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    owner = "receipt-test-#{System.unique_integer([:positive])}"
    key_file = Path.join(dir, "master-key")
    File.write!(key_file, Base.encode64(:crypto.strong_rand_bytes(32)))
    File.chmod!(key_file, 0o600)
    opts = [owner: owner, node_id: "node-a", key_providers: [:file], key_file: key_file]

    on_exit(fn ->
      for {{^owner, _} = ref, _} <- Store.list(Secrets.table()),
          do: Store.delete(Secrets.table(), ref)
    end)

    %{opts: opts, owner: owner, dir: dir}
  end

  test "lost response is reconciled without keys, values, replay or usage updates", ctx do
    fixed = Keyword.put(ctx.opts, :operation_id, "install:token-1")
    assert {:ok, metadata} = Secrets.set("token", "private-value", fixed)
    assert metadata.operation_id == "install:token-1"
    before = row(ctx, "token")

    # Even a missing master key cannot turn this query into a value read.
    query_opts = Keyword.put(ctx.opts, :key_file, Path.join(ctx.dir, "missing"))
    assert {:ok, proof} = Secrets.receipt("install:token-1", query_opts)

    assert proof == %{
             node_id: "node-a",
             operation_id: "install:token-1",
             status: "applied",
             name: "token",
             current_binding_matches: true
           }

    assert row(ctx, "token") == before
    refute inspect(proof) =~ "private-value"
    refute Map.has_key?(proof, :intent)
    refute Map.has_key?(metadata, :receipts)
    assert {:ok, duplicate} = Secrets.set("token", "private-value", fixed)
    assert duplicate == metadata
    assert row(ctx, "token") == before

    assert {:ok, "private-value"} = Secrets.get("token", ctx.opts)
    used = row(ctx, "token")
    assert used.usage_count == 1
    assert {:ok, %{current_binding_matches: true}} = Secrets.receipt("install:token-1", ctx.opts)
    assert row(ctx, "token") == used
  end

  test "conflicting value or name never replays a globally scoped operation", ctx do
    fixed = Keyword.put(ctx.opts, :operation_id, "operation")
    assert {:ok, _} = Secrets.set("token", "original", fixed)
    before = row(ctx, "token")

    for {name, value} <- [{"token", "different"}, {"other-name", "original"}] do
      assert {:error, :secret_operation_conflict} = Secrets.set(name, value, fixed)
    end

    assert row(ctx, "token") == before
    assert {:error, :not_found} = Secrets.get("other-name", ctx.opts)
  end

  test "ordinary replacement and deletion preserve historical proof but invalidate binding",
       ctx do
    fixed = Keyword.put(ctx.opts, :operation_id, "operation")
    assert {:ok, _} = Secrets.set("token", "original", fixed)
    assert {:ok, _} = Secrets.set("token", "original", ctx.opts)

    assert {:ok, %{status: "applied", current_binding_matches: false}} =
             Secrets.receipt("operation", ctx.opts)

    assert {:error, :secret_operation_conflict} = Secrets.set("token", "original", fixed)
    assert :ok = Secrets.delete("token", ctx.opts)
    assert :ok = Secrets.delete("token", ctx.opts)
    tombstone = row(ctx, "token")
    assert Receipts.receipt_only?(tombstone)
    assert {:error, :not_found} = Secrets.get("token", ctx.opts)
    assert {:ok, []} = Secrets.list(ctx.opts)

    assert {:ok, %{status: "applied", name: "token", current_binding_matches: false}} =
             Secrets.receipt("operation", ctx.opts)

    assert {:error, :secret_operation_conflict} = Secrets.set("token", "original", fixed)
    assert row(ctx, "token") == tombstone
    assert {:ok, _} = Secrets.set("token", "new", ctx.opts)

    assert {:ok, %{status: "applied", current_binding_matches: false}} =
             Secrets.receipt("operation", ctx.opts)
  end

  test "owner and authenticated node identities isolate fixed operation IDs", ctx do
    fixed = Keyword.put(ctx.opts, :operation_id, "shared")
    assert {:ok, _} = Secrets.set("token", "value", fixed)

    for opts <- [
          Keyword.put(ctx.opts, :owner, ctx.owner <> "-other"),
          Keyword.put(ctx.opts, :node_id, "node-b")
        ] do
      assert {:ok, %{status: "not_found", name: nil, current_binding_matches: false}} =
               Secrets.receipt("shared", opts)
    end

    node_b = fixed |> Keyword.put(:node_id, "node-b")
    assert {:ok, _} = Secrets.set("token", "value-b", node_b)
    assert {:ok, %{current_binding_matches: false}} = Secrets.receipt("shared", ctx.opts)

    assert {:ok, %{current_binding_matches: true}} =
             Secrets.receipt("shared", Keyword.put(ctx.opts, :node_id, "node-b"))
  end

  test "expiry changes current binding without deleting historical proof", ctx do
    opts =
      ctx.opts
      |> Keyword.put(:operation_id, "expires")
      |> Keyword.put(:expires_at, Clock.now_ms() + 60_000)

    assert {:ok, _} = Secrets.set("token", "value", opts)
    entry = row(ctx, "token") |> Map.put(:expires_at, Clock.now_ms() - 1)
    assert :ok = Store.put(Secrets.table(), {ctx.owner, "token"}, entry)
    assert {:error, :expired} = Secrets.get("token", ctx.opts)
    assert {:ok, []} = Secrets.list(ctx.opts)

    assert {:ok, %{status: "applied", current_binding_matches: false}} =
             Secrets.receipt("expires", ctx.opts)

    assert row(ctx, "token") == entry
  end

  test "JSONL reload preserves ciphertext, proof and intent comparison", ctx do
    fixed = Keyword.put(ctx.opts, :operation_id, "reload")
    assert {:ok, _} = Secrets.set("token", "value", fixed)
    entry = row(ctx, "token")
    path = Path.join(ctx.dir, "jsonl")
    assert {:ok, backend} = JsonlBackend.init(path: path)

    assert {:ok, _backend} =
             JsonlBackend.put(backend, Secrets.table(), {ctx.owner, "token"}, entry)

    assert {:ok, reloaded} = JsonlBackend.init(path: path)
    assert {:ok, entry, _} = JsonlBackend.get(reloaded, Secrets.table(), {ctx.owner, "token"})

    for representation <- [entry, entry |> Jason.encode!() |> Jason.decode!()] do
      assert :ok = Store.put(Secrets.table(), {ctx.owner, "token"}, representation)
      assert {:ok, %{current_binding_matches: true}} = Secrets.receipt("reload", ctx.opts)
      assert {:ok, _} = Secrets.set("token", "value", fixed)
      assert row(ctx, "token") == representation
    end
  end

  test "concurrent names cannot claim the same owner and node operation ID", ctx do
    fixed = Keyword.put(ctx.opts, :operation_id, "concurrent")

    results =
      1..8
      |> Task.async_stream(fn index -> Secrets.set("token-#{index}", "value", fixed) end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :secret_operation_conflict})) == 7
    assert {:ok, [%{name: name}]} = Secrets.list(ctx.opts)

    assert {:ok, %{name: ^name, status: "applied", current_binding_matches: true}} =
             Secrets.receipt("concurrent", ctx.opts)
  end

  test "bounded capacity rejects without pruning proof or replacing a value", ctx do
    for index <- 1..128 do
      assert {:ok, _} =
               Secrets.set("token", "value", Keyword.put(ctx.opts, :operation_id, "op-#{index}"))
    end

    before = row(ctx, "token")

    assert {:error, :secret_receipt_capacity} =
             Secrets.set("token", "new", Keyword.put(ctx.opts, :operation_id, "overflow"))

    assert row(ctx, "token") == before

    assert {:ok, %{status: "applied", current_binding_matches: false}} =
             Secrets.receipt("op-1", ctx.opts)

    assert {:ok, %{status: "applied", current_binding_matches: true}} =
             Secrets.receipt("op-128", ctx.opts)
  end

  test "invalid IDs and corrupt receipts fail closed with content-free errors", ctx do
    for id <- [nil, "", "a b", "a/b", "é", String.duplicate("a", 129)] do
      assert {:error, :invalid_operation_id} =
               Secrets.set(
                 "private-name",
                 "private-value",
                 Keyword.put(ctx.opts, :operation_id, id)
               )

      assert {:error, :invalid_operation_id} = Secrets.receipt(id, ctx.opts)
    end

    assert {:error, :invalid_node_id} =
             Secrets.set(
               "token",
               "value",
               [operation_id: "ok"] ++ Keyword.delete(ctx.opts, :node_id)
             )

    assert :ok =
             Store.put(Secrets.table(), {ctx.owner, "private-name"}, %{receipts: "private-value"})

    assert {:error, :secret_store_failed} = Secrets.receipt("ok", ctx.opts)
    assert {:error, :secret_store_failed} = Secrets.set("private-name", "new", ctx.opts)
  end

  test "strict read and failed single-row write cannot invent an applied receipt", ctx do
    for fault <- [:read, :write] do
      with_backend(%{data: %{}, fault: fault, test_pid: self()}, fn ->
        assert {:error, :secret_store_failed} =
                 Secrets.set("token", "value", Keyword.put(ctx.opts, :operation_id, "failure"))

        state = :sys.get_state(Store)
        refute Map.has_key?(state.backend_state.data, {Secrets.table(), {ctx.owner, "token"}})

        if fault == :read do
          assert {:error, :secret_store_failed} = Secrets.receipt("failure", ctx.opts)
        else
          assert {:ok, %{status: "not_found"}} = Secrets.receipt("failure", ctx.opts)
        end

        refute_receive {:vault_put, _, _, _}
      end)
    end
  end

  test "caller crash after admission leaves one indivisible vault and proof row", ctx do
    with_backend(%{data: %{}, fault: :pause, test_pid: self()}, fn ->
      writer =
        spawn(fn ->
          Secrets.set("token", "value", Keyword.put(ctx.opts, :operation_id, "crash"))
        end)

      monitor = Process.monitor(writer)
      assert_receive {:vault_put, store_pid, {owner, "token"}, record}
      assert owner == ctx.owner
      assert is_binary(record.ciphertext)
      assert [%{operation_id: "crash"}] = record.receipts
      Process.exit(writer, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}
      send(store_pid, :continue)

      assert {:ok, %{status: "applied", current_binding_matches: true}} =
               Secrets.receipt("crash", ctx.opts)

      before = row(ctx, "token")

      assert {:ok, _} =
               Secrets.set("token", "value", Keyword.put(ctx.opts, :operation_id, "crash"))

      assert row(ctx, "token") == before
      refute_receive {:vault_put, _, _, _}
    end)
  end

  defp row(ctx, name), do: Store.get(Secrets.table(), {ctx.owner, name})

  defp with_backend(backend_state, fun) do
    original = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: FaultBackend, backend_state: backend_state})

    try do
      fun.()
    after
      :sys.replace_state(Store, fn _ -> original end)
    end
  end
end
