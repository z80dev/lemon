defmodule Ai.ModelCacheTest do
  use ExUnit.Case, async: false

  alias Ai.ModelCache

  setup do
    start_supervised!(ModelCache)
    ModelCache.invalidate_all()
    :ok
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
      Process.sleep(2)

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
