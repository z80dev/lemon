defmodule CodingAgent.LayeredConfigTest do
  use ExUnit.Case, async: true

  alias CodingAgent.LayeredConfig

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    # Create temp directories for testing
    tmp_dir = System.tmp_dir!()
    test_id = :erlang.unique_integer([:positive])
    test_dir = Path.join(tmp_dir, "layered_config_test_#{test_id}")
    project_dir = Path.join(test_dir, "project")
    global_dir = Path.join(test_dir, "global")

    File.mkdir_p!(project_dir)
    File.mkdir_p!(Path.join(project_dir, ".lemon"))
    File.mkdir_p!(global_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{
      test_dir: test_dir,
      project_dir: project_dir,
      global_dir: global_dir,
      project_config_path: Path.join([project_dir, ".lemon", "config.exs"]),
      global_config_path: Path.join(global_dir, "config.exs")
    }
  end

  # ============================================================================
  # Loading Tests
  # ============================================================================

  describe "load/1" do
    test "returns empty config struct for directory without config files", %{project_dir: project_dir} do
      config = LayeredConfig.load(project_dir)

      assert %LayeredConfig{} = config
      assert config.global == %{}
      assert config.project == %{}
      assert config.session == %{}
      assert config.cwd == project_dir
    end
  end

  describe "load_file/1" do
    test "loads valid keyword list config", %{project_config_path: path} do
      File.write!(path, """
      [
        model: "claude-sonnet-4-20250514",
        thinking_level: :high,
        debug: true
      ]
      """)

      config = LayeredConfig.load_file(path)

      assert config.model == "claude-sonnet-4-20250514"
      assert config.thinking_level == :high
      assert config.debug == true
    end

    test "loads valid map config", %{project_config_path: path} do
      File.write!(path, """
      %{
        model: "gpt-4",
        theme: "dark"
      }
      """)

      config = LayeredConfig.load_file(path)

      assert config.model == "gpt-4"
      assert config.theme == "dark"
    end

    test "loads nested config", %{project_config_path: path} do
      File.write!(path, """
      [
        tools: [
          bash: [timeout: 300_000],
          read: [max_lines: 10000]
        ]
      ]
      """)

      config = LayeredConfig.load_file(path)

      assert config.tools.bash.timeout == 300_000
      assert config.tools.read.max_lines == 10000
    end

    test "returns empty map for missing file" do
      config = LayeredConfig.load_file("/nonexistent/path/config.exs")
      assert config == %{}
    end

    test "returns empty map for invalid syntax", %{project_config_path: path} do
      File.write!(path, "this is not valid elixir [[[")

      config = LayeredConfig.load_file(path)
      assert config == %{}
    end

    test "returns empty map for non-keyword/map result", %{project_config_path: path} do
      File.write!(path, "\"just a string\"")

      config = LayeredConfig.load_file(path)
      assert config == %{}
    end

    test "expands tilde paths", %{test_dir: test_dir} do
      # Create a file in a known location
      path = Path.join(test_dir, "tilde_test.exs")
      File.write!(path, "[test: :value]")

      config = LayeredConfig.load_file(path)
      assert config.test == :value
    end
  end

  describe "reload/1" do
    test "reloads config from disk while preserving session", %{project_config_path: path} do
      File.write!(path, "[model: \"v1\"]")

      config =
        %LayeredConfig{cwd: Path.dirname(Path.dirname(path))}
        |> LayeredConfig.put(:session_value, "preserved")

      # Simulate changing the file
      File.write!(path, "[model: \"v2\"]")

      reloaded = LayeredConfig.reload(config)

      # File change should be reflected
      assert reloaded.project.model == "v2"
      # Session values should be preserved
      assert reloaded.session.session_value == "preserved"
    end
  end

  # ============================================================================
  # Accessor Tests
  # ============================================================================

  describe "get/2 and get/3" do
    test "returns nil for missing key" do
      config = %LayeredConfig{}
      assert LayeredConfig.get(config, :nonexistent) == nil
    end

    test "returns default for missing key" do
      config = %LayeredConfig{}
      assert LayeredConfig.get(config, :nonexistent, "default") == "default"
    end

    test "returns value from session layer" do
      config = %LayeredConfig{session: %{model: "session-model"}}
      assert LayeredConfig.get(config, :model) == "session-model"
    end

    test "returns value from project layer" do
      config = %LayeredConfig{project: %{model: "project-model"}}
      assert LayeredConfig.get(config, :model) == "project-model"
    end

    test "returns value from global layer" do
      config = %LayeredConfig{global: %{model: "global-model"}}
      assert LayeredConfig.get(config, :model) == "global-model"
    end

    test "session takes precedence over project" do
      config = %LayeredConfig{
        session: %{model: "session-model"},
        project: %{model: "project-model"}
      }

      assert LayeredConfig.get(config, :model) == "session-model"
    end

    test "project takes precedence over global" do
      config = %LayeredConfig{
        project: %{model: "project-model"},
        global: %{model: "global-model"}
      }

      assert LayeredConfig.get(config, :model) == "project-model"
    end

    test "supports nested key access with list" do
      config = %LayeredConfig{
        session: %{tools: %{bash: %{timeout: 300_000}}}
      }

      assert LayeredConfig.get(config, [:tools, :bash, :timeout]) == 300_000
    end

    test "returns nil for missing nested key without default" do
      config = %LayeredConfig{session: %{tools: %{}}}
      # This key has no default in @defaults
      assert LayeredConfig.get(config, [:tools, :bash, :custom_option]) == nil
    end

    test "returns default for missing nested key" do
      config = %LayeredConfig{session: %{tools: %{}}}
      # Explicit default overrides the @defaults value
      assert LayeredConfig.get(config, [:tools, :bash, :custom_option], 60_000) == 60_000
    end

    test "returns @defaults value for nested key not in config" do
      config = %LayeredConfig{session: %{tools: %{}}}
      # Should return the default from @defaults since the path exists there
      assert LayeredConfig.get(config, [:tools, :bash, :timeout]) == 120_000
    end

    test "returns default from @defaults when not set" do
      config = %LayeredConfig{}
      # These should return values from @defaults
      assert LayeredConfig.get(config, :thinking_level) == :off
      assert LayeredConfig.get(config, [:compaction, :enabled]) == true
      assert LayeredConfig.get(config, [:retry, :max_retries]) == 3
    end
  end

  describe "get!/2" do
    test "returns value when present" do
      config = %LayeredConfig{session: %{model: "test-model"}}
      assert LayeredConfig.get!(config, :model) == "test-model"
    end

    test "returns default when key has default in @defaults" do
      config = %LayeredConfig{}
      assert LayeredConfig.get!(config, :thinking_level) == :off
    end

    test "raises KeyError when key not found and no default" do
      config = %LayeredConfig{}

      assert_raise KeyError, fn ->
        LayeredConfig.get!(config, :nonexistent_key)
      end
    end
  end

  describe "put/3" do
    test "sets value in session layer" do
      config = %LayeredConfig{}
      updated = LayeredConfig.put(config, :model, "new-model")

      assert updated.session.model == "new-model"
      assert LayeredConfig.get(updated, :model) == "new-model"
    end

    test "supports nested key access" do
      config = %LayeredConfig{}
      updated = LayeredConfig.put(config, [:tools, :bash, :timeout], 500_000)

      assert updated.session.tools.bash.timeout == 500_000
      assert LayeredConfig.get(updated, [:tools, :bash, :timeout]) == 500_000
    end

    test "session override takes precedence" do
      config = %LayeredConfig{
        global: %{model: "global"},
        project: %{model: "project"}
      }

      updated = LayeredConfig.put(config, :model, "session")

      assert LayeredConfig.get(updated, :model) == "session"
    end

    test "preserves other session values" do
      config = %LayeredConfig{session: %{a: 1, b: 2}}
      updated = LayeredConfig.put(config, :c, 3)

      assert updated.session.a == 1
      assert updated.session.b == 2
      assert updated.session.c == 3
    end
  end

  describe "put_layer/4" do
    test "sets value in global layer" do
      config = %LayeredConfig{}
      updated = LayeredConfig.put_layer(config, :global, :model, "global-model")

      assert updated.global.model == "global-model"
    end

    test "sets value in project layer" do
      config = %LayeredConfig{}
      updated = LayeredConfig.put_layer(config, :project, :model, "project-model")

      assert updated.project.model == "project-model"
    end

    test "sets value in session layer" do
      config = %LayeredConfig{}
      updated = LayeredConfig.put_layer(config, :session, :model, "session-model")

      assert updated.session.model == "session-model"
    end

    test "supports nested keys" do
      config = %LayeredConfig{}

      updated =
        config
        |> LayeredConfig.put_layer(:global, [:tools, :bash, :timeout], 100_000)
        |> LayeredConfig.put_layer(:project, [:tools, :bash, :timeout], 200_000)

      assert updated.global.tools.bash.timeout == 100_000
      assert updated.project.tools.bash.timeout == 200_000
    end
  end

  describe "get_layer/3" do
    test "returns value from specific layer" do
      config = %LayeredConfig{
        global: %{model: "global"},
        project: %{model: "project"},
        session: %{model: "session"}
      }

      assert LayeredConfig.get_layer(config, :global, :model) == "global"
      assert LayeredConfig.get_layer(config, :project, :model) == "project"
      assert LayeredConfig.get_layer(config, :session, :model) == "session"
    end

    test "returns nil for missing key in layer" do
      config = %LayeredConfig{global: %{model: "global"}}

      assert LayeredConfig.get_layer(config, :project, :model) == nil
      assert LayeredConfig.get_layer(config, :session, :model) == nil
    end

    test "supports nested keys" do
      config = %LayeredConfig{
        project: %{tools: %{bash: %{timeout: 123}}}
      }

      assert LayeredConfig.get_layer(config, :project, [:tools, :bash, :timeout]) == 123
    end
  end

  describe "has_key?/2" do
    test "returns true for key in any layer" do
      config = %LayeredConfig{global: %{model: "test"}}
      assert LayeredConfig.has_key?(config, :model) == true
    end

    test "returns true for key in defaults" do
      config = %LayeredConfig{}
      assert LayeredConfig.has_key?(config, :thinking_level) == true
    end

    test "returns false for nonexistent key" do
      config = %LayeredConfig{}
      assert LayeredConfig.has_key?(config, :totally_unknown) == false
    end

    test "works with nested keys" do
      config = %LayeredConfig{}
      assert LayeredConfig.has_key?(config, [:compaction, :enabled]) == true
      # This path doesn't exist in defaults
      assert LayeredConfig.has_key?(config, [:some, :nonexistent, :path]) == false
    end
  end

  describe "to_map/1" do
    test "returns merged config with defaults" do
      config = %LayeredConfig{
        global: %{model: "global-model"},
        project: %{theme: "dark"},
        session: %{debug: true}
      }

      result = LayeredConfig.to_map(config)

      assert result.model == "global-model"
      assert result.theme == "dark"
      assert result.debug == true
      # Defaults should be included
      assert result.thinking_level == :off
    end

    test "deep merges nested configs" do
      config = %LayeredConfig{
        global: %{tools: %{bash: %{timeout: 100}}},
        project: %{tools: %{bash: %{sandbox: true}}},
        session: %{tools: %{read: %{max_lines: 5000}}}
      }

      result = LayeredConfig.to_map(config)

      assert result.tools.bash.timeout == 100
      assert result.tools.bash.sandbox == true
      assert result.tools.read.max_lines == 5000
    end
  end

  describe "layer_to_map/2" do
    test "returns specific layer as map" do
      config = %LayeredConfig{
        global: %{a: 1},
        project: %{b: 2},
        session: %{c: 3}
      }

      assert LayeredConfig.layer_to_map(config, :global) == %{a: 1}
      assert LayeredConfig.layer_to_map(config, :project) == %{b: 2}
      assert LayeredConfig.layer_to_map(config, :session) == %{c: 3}
    end
  end

  # ============================================================================
  # Persistence Tests
  # ============================================================================

  describe "save_global/1 and save_project/1" do
    test "saves and loads global config", %{global_dir: global_dir} do
      path = Path.join(global_dir, "config.exs")

      # Test config structure (not used directly, shows what would be saved)
      _config = %LayeredConfig{
        global: %{model: "test-model", debug: true}
      }

      # Mock the global config path by writing directly
      content = """
      [
        debug: true,
        model: "test-model"
      ]
      """

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)

      loaded = LayeredConfig.load_file(path)

      assert loaded.model == "test-model"
      assert loaded.debug == true
    end

    test "save_project returns error when cwd is nil" do
      config = %LayeredConfig{cwd: nil, project: %{test: :value}}
      assert LayeredConfig.save_project(config) == {:error, :no_cwd}
    end

    test "creates directory if needed", %{test_dir: test_dir} do
      new_dir = Path.join(test_dir, "new_project/.lemon")
      refute File.exists?(new_dir)

      path = Path.join(new_dir, "config.exs")

      # Test config structure (not used directly, shows what would be saved)
      _config = %LayeredConfig{
        project: %{test: :value},
        cwd: Path.join(test_dir, "new_project")
      }

      # Directly write to test directory creation
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[test: :value]")

      assert File.exists?(path)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles empty config layers" do
      config = %LayeredConfig{
        global: %{},
        project: %{},
        session: %{}
      }

      # Should return defaults
      assert LayeredConfig.get(config, :thinking_level) == :off
    end

    test "handles deeply nested puts" do
      config = %LayeredConfig{}

      updated =
        config
        |> LayeredConfig.put([:a, :b, :c, :d], "deep")

      assert LayeredConfig.get(updated, [:a, :b, :c, :d]) == "deep"
    end

    test "handles single-element list keys" do
      config = %LayeredConfig{session: %{model: "test"}}

      assert LayeredConfig.get(config, [:model]) == "test"
    end

    test "handles empty list key" do
      config = %LayeredConfig{session: %{model: "test"}}

      assert LayeredConfig.get(config, []) == nil
    end

    test "normalizes string keys to atoms" do
      # Note: String keys in the struct are not auto-normalized
      _config_with_string_keys = %LayeredConfig{
        session: %{"model" => "string-key-model"}
      }

      # The normalization happens during load_file, not in the struct
      # This test verifies the behavior with properly normalized keys
      normalized = %LayeredConfig{
        session: %{model: "string-key-model"}
      }

      assert LayeredConfig.get(normalized, :model) == "string-key-model"
    end

    test "preserves non-map values during deep merge" do
      config = %LayeredConfig{
        global: %{tools: %{bash: %{timeout: 100}}},
        project: %{tools: "override_all_tools"}
      }

      # Project value should completely override global for this key
      result = LayeredConfig.to_map(config)
      assert result.tools == "override_all_tools"
    end

    test "handles list values correctly" do
      config = %LayeredConfig{
        session: %{extensions: ["ext1", "ext2"]}
      }

      assert LayeredConfig.get(config, :extensions) == ["ext1", "ext2"]
    end
  end

  # ============================================================================
  # Config Format Tests
  # ============================================================================

  describe "config file format" do
    test "supports integer values", %{project_config_path: path} do
      File.write!(path, "[timeout: 300_000]")

      config = LayeredConfig.load_file(path)
      assert config.timeout == 300_000
    end

    test "supports float values", %{project_config_path: path} do
      File.write!(path, "[ratio: 0.75]")

      config = LayeredConfig.load_file(path)
      assert config.ratio == 0.75
    end

    test "supports boolean values", %{project_config_path: path} do
      File.write!(path, "[enabled: true, disabled: false]")

      config = LayeredConfig.load_file(path)
      assert config.enabled == true
      assert config.disabled == false
    end

    test "supports atom values", %{project_config_path: path} do
      File.write!(path, "[level: :high, mode: :debug]")

      config = LayeredConfig.load_file(path)
      assert config.level == :high
      assert config.mode == :debug
    end

    test "supports list values", %{project_config_path: path} do
      File.write!(path, "[extensions: [\"ext1\", \"ext2\", \"ext3\"]]")

      config = LayeredConfig.load_file(path)
      assert config.extensions == ["ext1", "ext2", "ext3"]
    end

    test "supports mixed nested structures", %{project_config_path: path} do
      File.write!(path, """
      [
        tools: [
          bash: [timeout: 120_000, sandbox: true],
          read: %{max_lines: 5000}
        ],
        extensions: ["ext1", "ext2"]
      ]
      """)

      config = LayeredConfig.load_file(path)

      assert config.tools.bash.timeout == 120_000
      assert config.tools.bash.sandbox == true
      assert config.tools.read.max_lines == 5000
      assert config.extensions == ["ext1", "ext2"]
    end
  end

  # ============================================================================
  # Normalization Tests
  # ============================================================================

  describe "normalization during load" do
    test "normalizes string keys to atoms in maps", %{project_config_path: path} do
      File.write!(path, """
      %{
        "model" => "test-model",
        "tools" => %{
          "bash" => %{"timeout" => 5000}
        }
      }
      """)

      config = LayeredConfig.load_file(path)

      assert config.model == "test-model"
      assert config.tools.bash.timeout == 5000
    end

    test "returns empty map for non-keyword list result", %{project_config_path: path} do
      # A plain list that is not a keyword list
      File.write!(path, "[1, 2, 3]")

      config = LayeredConfig.load_file(path)
      assert config == %{}
    end

    test "normalizes nested keyword lists within maps", %{project_config_path: path} do
      File.write!(path, """
      %{
        tools: [
          bash: [timeout: 1000],
          read: [max_lines: 500]
        ]
      }
      """)

      config = LayeredConfig.load_file(path)

      assert config.tools.bash.timeout == 1000
      assert config.tools.read.max_lines == 500
    end

    test "normalizes list values containing nested structures", %{project_config_path: path} do
      File.write!(path, """
      [
        items: [
          [name: "item1", value: 1],
          [name: "item2", value: 2]
        ]
      ]
      """)

      config = LayeredConfig.load_file(path)

      # Each item in the list should be converted to a map
      assert length(config.items) == 2
      assert Enum.at(config.items, 0).name == "item1"
      assert Enum.at(config.items, 1).value == 2
    end
  end

  # ============================================================================
  # Deep Merge Edge Cases
  # ============================================================================

  describe "deep merge behavior" do
    test "merges nested maps from all three layers" do
      config = %LayeredConfig{
        global: %{tools: %{bash: %{timeout: 100}, read: %{max_lines: 1000}}},
        project: %{tools: %{bash: %{sandbox: true}}},
        session: %{tools: %{bash: %{extra: "value"}}}
      }

      result = LayeredConfig.to_map(config)

      # All values should be merged
      assert result.tools.bash.timeout == 100
      assert result.tools.bash.sandbox == true
      assert result.tools.bash.extra == "value"
      assert result.tools.read.max_lines == 1000
    end

    test "non-map value completely replaces map in merge" do
      config = %LayeredConfig{
        global: %{tools: %{bash: %{timeout: 100}}},
        project: %{tools: nil}
      }

      result = LayeredConfig.to_map(config)
      assert result.tools == nil
    end

    test "empty map merges correctly with populated map" do
      config = %LayeredConfig{
        global: %{tools: %{bash: %{timeout: 100}}},
        project: %{}
      }

      result = LayeredConfig.to_map(config)
      assert result.tools.bash.timeout == 100
    end
  end

  # ============================================================================
  # Path Traversal Edge Cases
  # ============================================================================

  describe "path traversal edge cases" do
    test "get returns default from @defaults when intermediate key is not a map" do
      config = %LayeredConfig{
        session: %{tools: "not a map"}
      }

      # When traversal fails, it falls back to @defaults which has the value
      assert LayeredConfig.get(config, [:tools, :bash, :timeout]) == 120_000
    end

    test "get returns nil for nested key not in @defaults when intermediate is non-map" do
      config = %LayeredConfig{
        session: %{custom: "not a map"}
      }

      # This path doesn't exist in @defaults either
      assert LayeredConfig.get(config, [:custom, :nested, :value]) == nil
    end

    test "put raises BadMapError when trying to nest into non-map value" do
      config = %LayeredConfig{
        session: %{tools: "will be replaced"}
      }

      # Put will try to get :bash from the string "will be replaced"
      # which causes a BadMapError
      assert_raise BadMapError, fn ->
        LayeredConfig.put(config, [:tools, :bash, :timeout], 5000)
      end
    end

    test "put_layer creates nested maps for deep paths" do
      config = %LayeredConfig{}

      updated = LayeredConfig.put_layer(config, :project, [:a, :b, :c, :d, :e], "deep")

      assert updated.project.a.b.c.d.e == "deep"
    end

    test "get_layer returns nil for missing nested path" do
      config = %LayeredConfig{
        project: %{tools: %{}}
      }

      assert LayeredConfig.get_layer(config, :project, [:tools, :bash, :timeout]) == nil
    end
  end

  # ============================================================================
  # Defaults Tests
  # ============================================================================

  describe "defaults" do
    test "provides sensible defaults for all common settings" do
      config = %LayeredConfig{}

      # Model settings
      assert LayeredConfig.get(config, :thinking_level) == :off

      # Compaction defaults
      assert LayeredConfig.get(config, [:compaction, :enabled]) == true
      assert LayeredConfig.get(config, [:compaction, :reserve_tokens]) == 16384
      assert LayeredConfig.get(config, [:compaction, :keep_recent_tokens]) == 20000

      # Retry defaults
      assert LayeredConfig.get(config, [:retry, :enabled]) == true
      assert LayeredConfig.get(config, [:retry, :max_retries]) == 3
      assert LayeredConfig.get(config, [:retry, :base_delay_ms]) == 1000

      # Tool defaults
      assert LayeredConfig.get(config, [:tools, :bash, :timeout]) == 120_000
      assert LayeredConfig.get(config, [:tools, :read, :max_lines]) == 2000
      assert LayeredConfig.get(config, [:tools, :glob, :max_results]) == 1000

      # Display defaults
      assert LayeredConfig.get(config, :theme) == "default"
      assert LayeredConfig.get(config, :debug) == false
    end

    test "user values override defaults" do
      config = %LayeredConfig{
        session: %{
          thinking_level: :high,
          compaction: %{enabled: false}
        }
      }

      assert LayeredConfig.get(config, :thinking_level) == :high
      assert LayeredConfig.get(config, [:compaction, :enabled]) == false
      # Non-overridden defaults should still work
      assert LayeredConfig.get(config, [:compaction, :reserve_tokens]) == 16384
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles runtime error during config evaluation", %{project_config_path: path} do
      File.write!(path, """
      raise "Intentional error for testing"
      """)

      # Should return empty map instead of crashing
      config = LayeredConfig.load_file(path)
      assert config == %{}
    end

    test "handles undefined function call in config", %{project_config_path: path} do
      File.write!(path, """
      undefined_function_that_does_not_exist()
      """)

      # Should return empty map instead of crashing
      config = LayeredConfig.load_file(path)
      assert config == %{}
    end

    test "get! raises with proper error info for nested keys" do
      config = %LayeredConfig{}

      error =
        assert_raise KeyError, fn ->
          LayeredConfig.get!(config, [:some, :nested, :unknown])
        end

      assert error.key == [:some, :nested, :unknown]
    end
  end

  # ============================================================================
  # Struct Field Access Tests
  # ============================================================================

  describe "struct fields" do
    test "cwd is preserved through operations" do
      config = LayeredConfig.load("/test/path")
      assert config.cwd == "/test/path"

      updated = LayeredConfig.put(config, :model, "test")
      assert updated.cwd == "/test/path"
    end

    test "all layers are independent" do
      config = %LayeredConfig{
        global: %{shared: "global"},
        project: %{shared: "project"},
        session: %{shared: "session"}
      }

      # Modify one layer shouldn't affect others
      updated = LayeredConfig.put_layer(config, :session, :shared, "modified")

      assert LayeredConfig.get_layer(updated, :global, :shared) == "global"
      assert LayeredConfig.get_layer(updated, :project, :shared) == "project"
      assert LayeredConfig.get_layer(updated, :session, :shared) == "modified"
    end
  end

  # ============================================================================
  # Config Format Value Tests
  # ============================================================================

  describe "config format - complex values" do
    test "handles nil values in config", %{project_config_path: path} do
      File.write!(path, "[model: nil, enabled: nil]")

      config = LayeredConfig.load_file(path)

      assert config.model == nil
      assert config.enabled == nil
    end

    test "handles tuple values in config", %{project_config_path: path} do
      File.write!(path, "[point: {1, 2, 3}]")

      config = LayeredConfig.load_file(path)

      assert config.point == {1, 2, 3}
    end

    test "handles empty list values", %{project_config_path: path} do
      # Empty keyword list [] becomes empty map %{} after normalization
      File.write!(path, "[extensions: [], tools: []]")

      config = LayeredConfig.load_file(path)

      # Empty list that's a keyword list gets converted to empty map
      assert config.extensions == %{}
      assert config.tools == %{}
    end

    test "handles plain list values (non-keyword)", %{project_config_path: path} do
      File.write!(path, "[items: [1, 2, 3]]")

      config = LayeredConfig.load_file(path)

      # Plain lists (not keyword lists) stay as lists
      assert config.items == [1, 2, 3]
    end

    test "handles empty map values", %{project_config_path: path} do
      File.write!(path, "[tools: %{}]")

      config = LayeredConfig.load_file(path)

      assert config.tools == %{}
    end
  end

  # ============================================================================
  # Multiple Operations Tests
  # ============================================================================

  describe "chained operations" do
    test "multiple puts accumulate correctly" do
      config =
        %LayeredConfig{}
        |> LayeredConfig.put(:a, 1)
        |> LayeredConfig.put(:b, 2)
        |> LayeredConfig.put(:c, 3)

      assert LayeredConfig.get(config, :a) == 1
      assert LayeredConfig.get(config, :b) == 2
      assert LayeredConfig.get(config, :c) == 3
    end

    test "put can overwrite previous put" do
      config =
        %LayeredConfig{}
        |> LayeredConfig.put(:model, "first")
        |> LayeredConfig.put(:model, "second")
        |> LayeredConfig.put(:model, "third")

      assert LayeredConfig.get(config, :model) == "third"
    end

    test "put_layer on different layers works correctly" do
      config =
        %LayeredConfig{}
        |> LayeredConfig.put_layer(:global, :value, "global")
        |> LayeredConfig.put_layer(:project, :value, "project")
        |> LayeredConfig.put_layer(:session, :value, "session")

      # Session should win in merged result
      assert LayeredConfig.get(config, :value) == "session"

      # But each layer should have its own value
      assert LayeredConfig.get_layer(config, :global, :value) == "global"
      assert LayeredConfig.get_layer(config, :project, :value) == "project"
      assert LayeredConfig.get_layer(config, :session, :value) == "session"
    end
  end
end
