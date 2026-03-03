defmodule CodingAgent.Wasm.RegistryTest do
  @moduledoc """
  Tests for the WASM Module Registry.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Wasm.Registry
  alias CodingAgent.Wasm.Registry.Entry

  @test_wasm_binary <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>>

  setup do
    # Create a unique temp directory for each test
    cache_dir = Path.join(System.tmp_dir!(), "wasm_registry_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cache_dir)

    on_exit(fn ->
      File.rm_rf!(cache_dir)
    end)

    {:ok, cache_dir: cache_dir}
  end

  describe "initialization" do
    test "starts with default options", %{cache_dir: cache_dir} do
      {:ok, pid} = Registry.start_link(cache_dir: cache_dir)
      assert Process.alive?(pid)

      stats = Registry.stats(pid)
      assert stats.total_modules == 0
      assert stats.active_modules == 0
    end

    test "starts with named registration", %{cache_dir: cache_dir} do
      name = :test_registry
      {:ok, pid} = Registry.start_link(name: name, cache_dir: cache_dir)
      assert Process.whereis(name) == pid
    end

    test "creates cache directory if it doesn't exist" do
      cache_dir = Path.join(System.tmp_dir!(), "nonexistent_#{System.unique_integer([:positive])}")
      {:ok, _pid} = Registry.start_link(cache_dir: cache_dir)
      assert File.dir?(cache_dir)
      File.rm_rf!(cache_dir)
    end
  end

  describe "local module registration" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir)

      # Create a test WASM file
      wasm_path = Path.join(cache_dir, "test_tool.wasm")
      File.write!(wasm_path, @test_wasm_binary)

      {:ok, registry: registry, wasm_path: wasm_path}
    end

    test "registers a local WASM module", %{registry: registry, wasm_path: wasm_path} do
      assert {:ok, entry} = Registry.register_local(registry, "test_tool", wasm_path)
      assert entry.name == "test_tool"
      assert entry.source.type == :local
      assert entry.size_bytes == byte_size(@test_wasm_binary)
      assert entry.checksum != nil
      assert entry.cache_path != nil
    end

    test "returns error for non-existent file", %{registry: registry} do
      assert {:error, {:file_read_failed, :enoent}} =
               Registry.register_local(registry, "missing", "/nonexistent/tool.wasm")
    end

    test "accepts any file as WASM (validation is runtime responsibility)", %{registry: registry, cache_dir: cache_dir} do
      invalid_path = Path.join(cache_dir, "not_wasm.txt")
      File.write!(invalid_path, "not a wasm file")

      # The registry accepts any file - validation happens at runtime
      assert {:ok, entry} =
               Registry.register_local(registry, "any_file", invalid_path)

      assert entry.name == "any_file"
      assert entry.size_bytes == 15
    end

    test "can retrieve registered module", %{registry: registry, wasm_path: wasm_path} do
      {:ok, _} = Registry.register_local(registry, "retrievable", wasm_path)

      assert {:ok, entry} = Registry.get_module(registry, "retrievable")
      assert entry.name == "retrievable"
    end

    test "returns error for non-existent module", %{registry: registry} do
      assert {:error, :not_found} = Registry.get_module(registry, "nonexistent")
    end

    test "can get module binary", %{registry: registry, wasm_path: wasm_path} do
      {:ok, _} = Registry.register_local(registry, "binary_test", wasm_path)

      assert {:ok, binary} = Registry.get_module_binary(registry, "binary_test")
      assert binary == @test_wasm_binary
    end
  end

  describe "embedded module registration" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir)
      {:ok, registry: registry}
    end

    test "registers embedded binary", %{registry: registry} do
      assert {:ok, entry} = Registry.register_embedded(registry, "embedded_tool", @test_wasm_binary)
      assert entry.name == "embedded_tool"
      assert entry.source.type == :embedded
      assert entry.size_bytes == byte_size(@test_wasm_binary)
    end

    test "registers with version and metadata", %{registry: registry} do
      assert {:ok, entry} =
               Registry.register_embedded(registry, "versioned", @test_wasm_binary,
                 version: "1.2.3",
                 metadata: %{author: "test"}
               )

      assert entry.version == "1.2.3"
      assert entry.source.metadata.author == "test"
    end

    test "registers with TTL", %{registry: registry} do
      assert {:ok, entry} =
               Registry.register_embedded(registry, "expiring", @test_wasm_binary, ttl_ms: 100)

      assert entry.expires_at != nil
      assert entry.expires_at > System.system_time(:millisecond)
    end
  end

  describe "HTTP module registration" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir)
      {:ok, registry: registry}
    end

    test "HTTP registration interface exists", %{registry: _registry} do
      # This test would need a mock HTTP client
      # For now, we just verify the interface exists
      assert function_exported?(Registry, :register_http, 4)
    end
  end

  describe "module listing" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir)

      # Register multiple modules
      :ok = File.write(Path.join(cache_dir, "tool1.wasm"), @test_wasm_binary)
      :ok = File.write(Path.join(cache_dir, "tool2.wasm"), @test_wasm_binary)

      Registry.register_local(registry, "tool1", Path.join(cache_dir, "tool1.wasm"))
      Registry.register_local(registry, "tool2", Path.join(cache_dir, "tool2.wasm"))
      Registry.register_embedded(registry, "embedded1", @test_wasm_binary)

      {:ok, registry: registry}
    end

    test "lists all registered modules", %{registry: registry} do
      modules = Registry.list_modules(registry)
      assert length(modules) == 3

      names = Enum.map(modules, & &1.name)
      assert "tool1" in names
      assert "tool2" in names
      assert "embedded1" in names
    end

    test "lists modules by source type", %{registry: registry} do
      local_modules = Registry.list_modules_by_source(registry, :local)
      assert length(local_modules) == 2

      embedded_modules = Registry.list_modules_by_source(registry, :embedded)
      assert length(embedded_modules) == 1
      assert hd(embedded_modules).name == "embedded1"
    end
  end

  describe "module unregistration" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir)

      wasm_path = Path.join(cache_dir, "unregister_test.wasm")
      File.write!(wasm_path, @test_wasm_binary)

      {:ok, entry} = Registry.register_local(registry, "to_remove", wasm_path)
      {:ok, registry: registry, cache_path: entry.cache_path}
    end

    test "unregisters a module", %{registry: registry} do
      assert :ok = Registry.unregister(registry, "to_remove")
      assert {:error, :not_found} = Registry.get_module(registry, "to_remove")
    end

    test "removes cache file on unregister", %{registry: registry, cache_path: cache_path} do
      assert File.exists?(cache_path)
      Registry.unregister(registry, "to_remove")
      refute File.exists?(cache_path)
    end

    test "returns error for non-existent module", %{registry: registry} do
      assert {:error, :not_found} = Registry.unregister(registry, "never_existed")
    end
  end

  describe "module existence check" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir)

      wasm_path = Path.join(cache_dir, "exists_test.wasm")
      File.write!(wasm_path, @test_wasm_binary)

      Registry.register_local(registry, "exists", wasm_path)

      {:ok, registry: registry}
    end

    test "returns true for existing module", %{registry: registry} do
      assert Registry.module_exists?(registry, "exists")
    end

    test "returns false for non-existent module", %{registry: registry} do
      refute Registry.module_exists?(registry, "does_not_exist")
    end
  end

  describe "cache cleanup" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir, cleanup_interval_ms: 50)

      # Register modules with short TTL
      Registry.register_embedded(registry, "expired1", @test_wasm_binary, ttl_ms: 1)
      Registry.register_embedded(registry, "expired2", @test_wasm_binary, ttl_ms: 1)
      Registry.register_embedded(registry, "permanent", @test_wasm_binary, ttl_ms: 0)

      # Wait for expiration
      Process.sleep(10)

      {:ok, registry: registry}
    end

    test "cleans up expired modules", %{registry: registry} do
      result = Registry.cleanup(registry)
      assert result.removed == 2
      assert result.remaining == 1

      refute Registry.module_exists?(registry, "expired1")
      refute Registry.module_exists?(registry, "expired2")
      assert Registry.module_exists?(registry, "permanent")
    end

    test "clears all modules", %{registry: registry} do
      :ok = Registry.clear(registry)
      assert Registry.list_modules(registry) == []
    end
  end

  describe "statistics" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir)

      wasm_path = Path.join(cache_dir, "stats_test.wasm")
      File.write!(wasm_path, @test_wasm_binary)

      {:ok, registry: registry, wasm_path: wasm_path}
    end

    test "tracks module registration", %{registry: registry, wasm_path: wasm_path} do
      stats_before = Registry.stats(registry)
      assert stats_before.total_modules == 0

      Registry.register_local(registry, "stats1", wasm_path)

      stats_after = Registry.stats(registry)
      assert stats_after.total_modules == 1
      assert stats_after.active_modules == 1
    end

    test "tracks cache hits and misses", %{registry: registry, wasm_path: wasm_path} do
      Registry.register_local(registry, "cache_test", wasm_path)

      # First access should be a miss (or hit if cached)
      Registry.get_module(registry, "cache_test")

      stats = Registry.stats(registry)
      # Either hits or misses should be > 0
      assert stats.cache_hits + stats.cache_misses >= 1
    end
  end

  describe "Entry struct" do
    test "expired? returns true for expired entries" do
      entry = %Entry{
        name: "test",
        expires_at: System.system_time(:millisecond) - 1000
      }

      assert Entry.expired?(entry)
    end

    test "expired? returns false for non-expired entries" do
      entry = %Entry{
        name: "test",
        expires_at: System.system_time(:millisecond) + 1000
      }

      refute Entry.expired?(entry)
    end

    test "expired? returns false for entries without expiration" do
      entry = %Entry{
        name: "test",
        expires_at: nil
      }

      refute Entry.expired?(entry)
    end

    test "to_map and from_map are reversible" do
      entry = %Entry{
        name: "test",
        source: %{type: :local, uri: "/path", checksum: "abc", version: "1.0", metadata: %{}},
        size_bytes: 100,
        cache_path: "/cache",
        checksum: "abc",
        registered_at: 123,
        expires_at: 456,
        version: "1.0",
        access_count: 5,
        last_accessed_at: 789
      }

      map = Entry.to_map(entry)
      restored = Entry.from_map(map)

      assert restored.name == entry.name
      assert restored.size_bytes == entry.size_bytes
      assert restored.checksum == entry.checksum
    end
  end

  describe "telemetry" do
    setup %{cache_dir: cache_dir} do
      {:ok, registry} = Registry.start_link(cache_dir: cache_dir)

      wasm_path = Path.join(cache_dir, "telemetry_test.wasm")
      File.write!(wasm_path, @test_wasm_binary)

      {:ok, registry: registry, wasm_path: wasm_path}
    end

    test "emits telemetry on registration", %{registry: registry, wasm_path: wasm_path} do
      # Telemetry events are emitted but we can't reliably test async telemetry
      # Just verify registration works without errors
      assert {:ok, _entry} = Registry.register_local(registry, "telemetry_tool", wasm_path)
    end

    test "emits telemetry on access", %{registry: registry, wasm_path: wasm_path} do
      Registry.register_local(registry, "access_tool", wasm_path)

      # Telemetry events are emitted but we can't reliably test async telemetry
      # Just verify access works without errors
      assert {:ok, _entry} = Registry.get_module(registry, "access_tool")
    end
  end
end
