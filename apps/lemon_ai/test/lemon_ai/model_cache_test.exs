defmodule LemonAi.ModelCacheTest do
  use ExUnit.Case, async: false

  alias LemonAi.ModelCache

  setup do
    if Process.whereis(ModelCache) == nil do
      start_supervised!(ModelCache)
    end

    ModelCache.invalidate_all()
    :ok
  end

  test "writes survive the caller and remain owned by the supervised cache" do
    owner = Process.whereis(ModelCache)

    assert Enum.any?(Supervisor.which_children(LemonAi.Supervisor), fn
             {ModelCache, ^owner, :worker, _} -> true
             _ -> false
           end)

    task = Task.async(fn -> ModelCache.write("short-lived", ["model"]) end)
    assert Task.await(task) == :ok
    monitor = Process.monitor(task.pid)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert :ets.info(:ai_model_cache, :owner) == owner
    assert {:ok, %{models: ["model"]}} = ModelCache.read("short-lived")
  end

  test "does not adopt a table owned by an unrelated caller" do
    assert :ok = Supervisor.terminate_child(LemonAi.Supervisor, ModelCache)
    table = :ets.new(:ai_model_cache, [:named_table, :public, :set])

    try do
      assert {:error, {:badarg, _stack}} = GenServer.start(ModelCache, [])
      assert :ets.info(table, :owner) == self()
    after
      :ets.delete(table)
      {:ok, _pid} = Supervisor.restart_child(LemonAi.Supervisor, ModelCache)
    end
  end

  test "restarts with an empty table owned by the new supervised process" do
    old_owner = Process.whereis(ModelCache)
    ModelCache.write("before-restart", ["model"])
    assert :ok = Supervisor.terminate_child(LemonAi.Supervisor, ModelCache)

    try do
      assert :ets.whereis(:ai_model_cache) == :undefined
    after
      {:ok, _pid} = Supervisor.restart_child(LemonAi.Supervisor, ModelCache)
    end

    owner = Process.whereis(ModelCache)
    assert owner != old_owner
    assert :ets.info(:ai_model_cache, :owner) == owner
    assert :miss = ModelCache.read("before-restart")
  end

  describe "read/2" do
    test "returns :miss on empty cache" do
      assert :miss = ModelCache.read("openai")
    end
  end

  describe "write/3 and read/2" do
    test "write then read returns cached data" do
      models = ["gpt-4", "gpt-3.5-turbo"]
      assert :ok = ModelCache.write("openai", models)

      assert {:ok, result} = ModelCache.read("openai")
      assert result.models == models
      assert result.fresh == true
      assert result.authoritative == false
      assert is_integer(result.updated_at)
    end

    test "returns stale when TTL expires" do
      ModelCache.write("openai", ["gpt-4"])
      :ets.update_element(:ai_model_cache, "openai", {3, System.monotonic_time(:millisecond) - 2})

      assert {:ok, result} = ModelCache.read("openai", 1)
      assert result.fresh == false
      assert result.models == ["gpt-4"]
    end
  end

  describe "invalidate/1" do
    test "removes a specific entry" do
      ModelCache.write("openai", ["gpt-4"])
      ModelCache.write("anthropic", ["claude-3"])

      assert :ok = ModelCache.invalidate("openai")
      assert :miss = ModelCache.read("openai")
      assert {:ok, _} = ModelCache.read("anthropic")
    end
  end

  describe "invalidate_all/0" do
    test "clears all entries" do
      ModelCache.write("openai", ["gpt-4"])
      ModelCache.write("anthropic", ["claude-3"])

      assert :ok = ModelCache.invalidate_all()
      assert :miss = ModelCache.read("openai")
      assert :miss = ModelCache.read("anthropic")
    end
  end

  describe "stats/0" do
    test "returns correct counts" do
      assert %{entries: 0, providers: []} = ModelCache.stats()

      ModelCache.write("openai", ["gpt-4"])
      ModelCache.write("anthropic", ["claude-3"])

      stats = ModelCache.stats()
      assert stats.entries == 2
      assert Enum.sort(stats.providers) == ["anthropic", "openai"]
    end
  end

  describe "authoritative flag" do
    test "defaults to false" do
      ModelCache.write("openai", ["gpt-4"])
      assert {:ok, %{authoritative: false}} = ModelCache.read("openai")
    end

    test "can be set to true" do
      ModelCache.write("openai", ["gpt-4"], authoritative: true)
      assert {:ok, %{authoritative: true}} = ModelCache.read("openai")
    end
  end
end
