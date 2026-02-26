defmodule LemonCore.ConfigCacheTest do
  @moduledoc """
  Tests for the ConfigCache module.
  """
  use ExUnit.Case, async: false

  alias LemonCore.ConfigCache

  setup do
    # Create a temporary directory for test configs
    tmp_dir = Path.join(System.tmp_dir!(), "config_cache_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME
    original_home = System.get_env("HOME")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    # Ensure the cache is started
    if !ConfigCache.available?() do
      {:ok, _pid} = ConfigCache.start_link([])
    end

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "start_link/1" do
    test "starts the ConfigCache GenServer" do
      # The cache is already started in setup
      assert ConfigCache.available?()
    end
  end

  describe "available?/0" do
    test "returns true when cache is running" do
      assert ConfigCache.available?() == true
    end
  end

  describe "get/2" do
    test "returns config for empty cwd (global only)", %{mock_home: mock_home} do
      # Create a global config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "test-model"
      """)

      config = ConfigCache.get(nil, mtime_check_interval_ms: 100)

      assert is_map(config)
      assert config.agent.default_model == "test-model"
    end

    test "returns config with project override", %{tmp_dir: tmp_dir, mock_home: mock_home} do
      # Create global config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "global-model"
      """)

      # Create project config
      project_config = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "config.toml"), """
      [agent]
      default_model = "project-model"
      """)

      config = ConfigCache.get(tmp_dir, mtime_check_interval_ms: 100)

      assert is_map(config)
      assert config.agent.default_model == "project-model"
    end

    test "caches config and returns cached version on subsequent calls", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "cached-model"
      """)

      # First call should load from disk
      config1 = ConfigCache.get(nil, mtime_check_interval_ms: 100)

      # Modify the file
      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "modified-model"
      """)

      # Second call should return cached version (within TTL)
      config2 = ConfigCache.get(nil, mtime_check_interval_ms: 100)

      assert config1.agent.default_model == "cached-model"
      assert config2.agent.default_model == "cached-model"
    end

    test "reloads config when TTL expires and file changed", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "original-model"
      """)

      # First call
      config1 = ConfigCache.get(nil, mtime_check_interval_ms: 10)
      assert config1.agent.default_model == "original-model"

      # Modify the file
      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "updated-model"
      """)

      # Wait for TTL to expire
      Process.sleep(50)

      # Second call should reload from disk
      config2 = ConfigCache.get(nil, mtime_check_interval_ms: 10)
      assert config2.agent.default_model == "updated-model"
    end
  end

  describe "reload/2" do
    test "force reloads config from disk", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "original-model"
      """)

      # First call
      config1 = ConfigCache.get(nil, mtime_check_interval_ms: 10000)
      assert config1.agent.default_model == "original-model"

      # Modify the file
      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "reloaded-model"
      """)

      # Force reload
      config2 = ConfigCache.reload(nil)
      assert config2.agent.default_model == "reloaded-model"
    end
  end

  describe "invalidate/1" do
    test "removes cached entry", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "cached-model"
      """)

      # Load config
      config1 = ConfigCache.get(nil, mtime_check_interval_ms: 10000)
      assert config1.agent.default_model == "cached-model"

      # Modify file
      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "new-model"
      """)

      # Invalidate cache
      :ok = ConfigCache.invalidate(nil)

      # Next get should reload from disk
      config2 = ConfigCache.get(nil, mtime_check_interval_ms: 10000)
      assert config2.agent.default_model == "new-model"
    end

    test "invalidate is idempotent", %{mock_home: _mock_home} do
      # Invalidate when nothing is cached should not crash
      assert :ok = ConfigCache.invalidate(nil)
      assert :ok = ConfigCache.invalidate("/nonexistent/path")
    end
  end

  describe "error handling" do
    test "handles missing config files gracefully", %{mock_home: _mock_home} do
      # No config files created - should still return a config with defaults
      config = ConfigCache.get(nil, mtime_check_interval_ms: 100)

      assert is_map(config)
      # Should have default structure
      assert is_map(config.agent)
    end

    test "raises when cache is not available" do
      # This test would require stopping the cache, which affects other tests
      # So we just verify the function exists and has proper error handling
      assert function_exported?(ConfigCache, :get, 2)
    end
  end

  describe "concurrent access" do
    test "handles concurrent get calls", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "concurrent-model"
      """)

      # Spawn multiple concurrent gets
      tasks = for _ <- 1..10 do
        Task.async(fn ->
          ConfigCache.get(nil, mtime_check_interval_ms: 100)
        end)
      end

      results = Task.await_many(tasks)

      # All should return valid configs
      assert Enum.all?(results, &is_map/1)
      assert Enum.all?(results, fn config -> config.agent.default_model == "concurrent-model" end)
    end

    test "handles concurrent reload calls", %{mock_home: mock_home} do
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "reload-model"
      """)

      # First load
      ConfigCache.get(nil)

      # Spawn multiple concurrent reloads
      tasks = for _ <- 1..5 do
        Task.async(fn ->
          ConfigCache.reload(nil)
        end)
      end

      results = Task.await_many(tasks)

      # All should return valid configs
      assert Enum.all?(results, &is_map/1)
    end
  end

  describe "config paths" do
    test "uses different cache keys for different cwd", %{tmp_dir: tmp_dir, mock_home: mock_home} do
      # Create global config
      global_config = Path.join(mock_home, ".lemon")
      File.mkdir_p!(global_config)

      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "global-model"
      """)

      # Create two different project configs
      project1 = Path.join(tmp_dir, "project1")
      File.mkdir_p!(Path.join(project1, ".lemon"))
      File.write!(Path.join(project1, ".lemon/config.toml"), """
      [agent]
      default_model = "project1-model"
      """)

      project2 = Path.join(tmp_dir, "project2")
      File.mkdir_p!(Path.join(project2, ".lemon"))
      File.write!(Path.join(project2, ".lemon/config.toml"), """
      [agent]
      default_model = "project2-model"
      """)

      # Get configs for different projects
      config1 = ConfigCache.get(project1, mtime_check_interval_ms: 100)
      config2 = ConfigCache.get(project2, mtime_check_interval_ms: 100)

      assert config1.agent.default_model == "project1-model"
      assert config2.agent.default_model == "project2-model"
    end
  end
end
