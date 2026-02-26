defmodule LemonCore.ConfigCacheValidationTest do
  @moduledoc """
  Tests for config cache validation on reload.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
    test "reload without validation does not log warnings", %{global_config: global_config} do
      # Create a config with validation issues
      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      # Invalidate cache to force reload
      ConfigCache.invalidate()

      # Reload without validation should not log warnings
      logs =
        capture_log(fn ->
          ConfigCache.reload(nil, [])
        end)

      refute logs =~ "Configuration validation warnings"
    end

    test "reload with validate: true logs warnings for invalid config", %{
      global_config: global_config
    } do
      # Create a config with validation issues
      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      # Invalidate cache to force reload
      ConfigCache.invalidate()

      # Reload with validation should log warnings
      logs =
        capture_log(fn ->
          ConfigCache.reload(nil, validate: true)
        end)

      assert logs =~ "Configuration validation warnings"
      assert logs =~ "agent.default_model"
    end

    test "reload with validate: true does not log warnings for valid config", %{
      global_config: global_config
    } do
      # Create a valid config
      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = "claude-sonnet-4"
      default_provider = "anthropic"
      default_thinking_level = "medium"
      """)

      # Invalidate cache to force reload
      ConfigCache.invalidate()

      # Reload with validation should not log warnings for valid config
      logs =
        capture_log(fn ->
          ConfigCache.reload(nil, validate: true)
        end)

      refute logs =~ "Configuration validation warnings"
    end
  end

  describe "get with automatic reload" do
    test "get does not validate by default", %{global_config: global_config} do
      # Create a config with validation issues
      File.write!(Path.join(global_config, "config.toml"), """
      [agent]
      default_model = ""
      """)

      # Invalidate cache
      ConfigCache.invalidate()

      # Get without validation should not log warnings
      logs =
        capture_log(fn ->
          ConfigCache.get()
        end)

      refute logs =~ "Configuration validation warnings"
    end
  end
end
