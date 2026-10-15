defmodule LemonCore.ConfigCacheValidationTest do
  @moduledoc """
  Tests for config cache validation on reload.
  """
  use ExUnit.Case, async: false

  alias LemonCore.ConfigCache

  setup do
    # Create a temporary directory for test configs
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_config_cache_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Create .lemon directory
    global_config = Path.join(mock_home, ".lemon")
    File.mkdir_p!(global_config)

    # Store original HOME and cwd
    original_home = System.get_env("HOME")
    original_cwd = File.cwd!()

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    # Ensure cache is available
    unless ConfigCache.available?() do
      {:ok, _pid} = LemonCore.ConfigCache.start_link()
    end

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Restore original cwd
      File.cd!(original_cwd)

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home, global_config: global_config}
  end

  describe "reload with validation" do
    test "reload rejects invalid configuration and names the file", %{
      global_config: global_config
    } do
      path = Path.join(global_config, "config.toml")
      File.write!(path, "[defaults]\nmodel = \"\"\n")
      ConfigCache.invalidate()

      error = assert_raise LemonCore.Config.ValidationError, fn -> ConfigCache.reload() end
      assert Exception.message(error) =~ path
      assert Exception.message(error) =~ "agent.default_model"
      assert ConfigCache.available?()
    end

    test "failed reload preserves the last good cached configuration", %{
      global_config: global_config
    } do
      path = Path.join(global_config, "config.toml")
      File.write!(path, "[defaults]\nmodel = \"last-good-model\"\n")
      assert ConfigCache.reload().agent.default_model == "last-good-model"

      File.write!(path, "[defaults]\nmodel = \"\"\n")
      assert_raise LemonCore.Config.ValidationError, fn -> ConfigCache.reload() end

      assert ConfigCache.get(nil, mtime_check_interval_ms: 60_000).agent.default_model ==
               "last-good-model"
    end

    test "valid reload replaces the cached configuration", %{global_config: global_config} do
      path = Path.join(global_config, "config.toml")
      File.write!(path, "[defaults]\nmodel = \"first-model\"\n")
      assert ConfigCache.reload().agent.default_model == "first-model"

      File.write!(path, "[defaults]\nmodel = \"replacement-model\"\n")
      assert ConfigCache.reload().agent.default_model == "replacement-model"
      assert ConfigCache.get().agent.default_model == "replacement-model"
    end
  end

  describe "get with automatic reload" do
    test "initial get validates and recovers after the file is corrected", %{
      global_config: global_config
    } do
      path = Path.join(global_config, "config.toml")
      File.write!(path, "[defaults]\nmodel = \"\"\n")
      ConfigCache.invalidate()
      assert_raise LemonCore.Config.ValidationError, fn -> ConfigCache.get() end

      File.write!(path, "[defaults]\nmodel = \"corrected-model\"\n")
      assert ConfigCache.get().agent.default_model == "corrected-model"
    end
  end
end
