defmodule LemonCore.Secrets.UsageTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Secrets, Store}
  alias LemonCore.Secrets.{Crypto, Usage}

  setup do
    store =
      start_supervised!(
        {Store,
         name: :secrets_usage_test_store, backend: LemonCore.Store.EtsBackend, cached_tables: []}
      )

    worker =
      start_supervised!({Usage, name: :secrets_usage_test_worker, flush_interval: :infinity})

    {:ok, encrypted} = Crypto.encrypt("private-value", :crypto.strong_rand_bytes(32))
    entry = Map.merge(encrypted, %{usage_count: 0, last_used_at: nil, updated_at: 123})
    key = {"default", "usage"}
    assert :ok = Store.put(store, Secrets.table(), key, entry)
    %{store: store, worker: worker, key: key, entry: entry}
  end

  test "casts coalesce a burst into one exact-record CAS", ctx do
    :erlang.trace(ctx.store, true, [:receive])

    for _ <- 1..20 do
      assert :ok = Usage.touch(ctx.store, ctx.key, ctx.entry, ctx.worker)
    end

    assert Store.get(ctx.store, Secrets.table(), ctx.key) == ctx.entry
    assert :ok = Usage.flush(ctx.worker)
    used = Store.get(ctx.store, Secrets.table(), ctx.key)
    assert used.usage_count == 20
    assert is_integer(used.last_used_at)
    assert used.updated_at == ctx.entry.updated_at

    store = ctx.store
    key = ctx.key
    entry = ctx.entry
    delivered = :erlang.trace_delivered(store)
    assert_receive {:trace_delivered, ^store, ^delivered}

    assert_received {:trace, ^store, :receive,
                     {:"$gen_call", _, {:generic_compare_and_swap, :secrets_v1, ^key, ^entry, _}}}

    refute_received {:trace, ^store, :receive,
                     {:"$gen_call", _, {:generic_compare_and_swap, :secrets_v1, ^key, _, _}}}

    :erlang.trace(store, false, [:receive])
  end

  for mutation <- [:delete, :replace, :stage] do
    @mutation mutation
    test "a delayed touch cannot undo #{@mutation}", ctx do
      assert :ok = Usage.touch(ctx.store, ctx.key, ctx.entry, ctx.worker)

      replacement =
        case @mutation do
          :delete ->
            nil

          :replace ->
            Map.put(ctx.entry, :incarnation, "replacement")

          :stage ->
            Map.put(
              ctx.entry,
              :staged,
              Map.take(ctx.entry, [:ciphertext, :nonce, :salt, :version])
            )
        end

      if replacement do
        assert :ok = Store.put(ctx.store, Secrets.table(), ctx.key, replacement)
      else
        assert :ok = Store.delete(ctx.store, Secrets.table(), ctx.key)
      end

      assert :ok = Usage.flush(ctx.worker)
      assert Store.get(ctx.store, Secrets.table(), ctx.key) == replacement
    end
  end

  test "an unavailable worker is best effort and does not write synchronously", ctx do
    assert :ok = Usage.touch(ctx.store, ctx.key, ctx.entry, :absent_secrets_usage_worker)
    assert Store.get(ctx.store, Secrets.table(), ctx.key) == ctx.entry
  end

  test "a dead Store cannot redirect delayed touches to its replacement", ctx do
    assert :ok = Usage.touch(ctx.store, ctx.key, ctx.entry, ctx.worker)
    stop_supervised!(Store)

    replacement =
      start_supervised!(
        {Store,
         name: :secrets_usage_test_store, backend: LemonCore.Store.EtsBackend, cached_tables: []}
      )

    assert :ok = Store.put(replacement, Secrets.table(), ctx.key, ctx.entry)
    assert :ok = Usage.flush(ctx.worker)
    assert Store.get(replacement, Secrets.table(), ctx.key) == ctx.entry
  end
end
