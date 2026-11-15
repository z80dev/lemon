defmodule LemonCore.Secrets.ReadCacheTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Secrets, Store}
  alias LemonCore.Secrets.{Lock, MasterKey}

  defmodule CountingKey do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :counting

    @impl true
    def fetch(opts) do
      Agent.get_and_update(Keyword.fetch!(opts, :key_agent), fn state ->
        {state.result, %{state | reads: state.reads + 1}}
      end)
    end
  end

  defmodule RunnerKeychain do
    def available?, do: true
    defdelegate get_master_key(opts), to: LemonCore.Secrets.Keychain
  end

  setup do
    store =
      start_supervised!(
        {Store, name: :secrets_read_cache_test, backend: LemonCore.Store.EtsBackend}
      )

    key = Base.encode64(:crypto.strong_rand_bytes(32))
    agent = start_supervised!({Agent, fn -> %{result: {:ok, key}, reads: 0} end})
    opts = [store: store, key_providers: [CountingKey], key_agent: agent]
    MasterKey.with_cache_invalidation(fn -> :ok end)
    on_exit(fn -> MasterKey.with_cache_invalidation(fn -> :ok end) end)
    %{store: store, agent: agent, opts: opts, key: key}
  end

  test "secret reads across processes invoke the security command only once", ctx do
    runner = fn "security", ["find-generic-password" | _], _opts ->
      Agent.get_and_update(ctx.agent, fn %{result: {:ok, key}} = state ->
        {{key, 0}, %{state | reads: state.reads + 1}}
      end)
    end

    opts =
      Keyword.merge(ctx.opts,
        key_providers: [:keychain],
        keychain_module: RunnerKeychain,
        runner: runner
      )

    assert {:ok, _} = Secrets.set("token", "private-value", opts)
    Agent.update(ctx.agent, &%{&1 | reads: 0})

    # Concurrent cold readers also share one resolution, not just warm readers.
    readers = for _ <- 1..8, do: Task.async(fn -> Secrets.get("token", opts) end)
    assert Enum.map(readers, &Task.await/1) == List.duplicate({:ok, "private-value"}, 8)
    assert {:ok, "private-value"} = Secrets.get("token", opts)
    assert Agent.get(ctx.agent, & &1.reads) == 1
  end

  test "failed resolutions are not retained", ctx do
    Agent.update(ctx.agent, &%{&1 | result: {:error, :missing}})
    assert {:error, :missing_master_key} = MasterKey.resolve_cached(ctx.opts)
    Agent.update(ctx.agent, &%{&1 | result: {:ok, ctx.key}})
    assert {:ok, _, :counting} = MasterKey.resolve_cached(ctx.opts)
    assert {:ok, _, :counting} = MasterKey.resolve_cached(ctx.opts)
    assert Agent.get(ctx.agent, & &1.reads) == 2
  end

  test "fresh writer resolution invalidates a cached key", ctx do
    assert {:ok, old, :counting} = MasterKey.resolve_cached(ctx.opts)
    encoded = Base.encode64(:crypto.strong_rand_bytes(32))
    Agent.update(ctx.agent, &%{&1 | result: {:ok, encoded}})
    assert {:ok, ^old, :counting} = MasterKey.resolve_cached(ctx.opts)

    assert {:ok, fresh, :counting} =
             Lock.with_write_lock(fn -> MasterKey.resolve_fresh(ctx.opts) end, ctx.store)

    refute old == fresh
    assert {:ok, ^fresh, :counting} = MasterKey.resolve_cached(ctx.opts)
  end

  test "a paused usage worker does not block secret reads", ctx do
    assert {:ok, _} = Secrets.set("token", "private-value", ctx.opts)
    worker = Process.whereis(LemonCore.Secrets.Usage)
    :ok = :sys.suspend(worker)

    try do
      reader = Task.async(fn -> Secrets.get("token", ctx.opts) end)
      assert Task.await(reader) == {:ok, "private-value"}
    after
      :sys.resume(worker)
    end
  end

  test "different provider options never share key material", ctx do
    other =
      start_supervised!(
        {Agent, fn -> %{result: {:ok, Base.encode64(:binary.copy(<<9>>, 32))}, reads: 0} end},
        id: :other_key
      )

    assert {:ok, first, :counting} = MasterKey.resolve_cached(ctx.opts)

    assert {:ok, second, :counting} =
             MasterKey.resolve_cached(Keyword.put(ctx.opts, :key_agent, other))

    refute first == second
  end
end
