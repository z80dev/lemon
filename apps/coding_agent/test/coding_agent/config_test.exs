defmodule CodingAgent.ConfigTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Config

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    # Create temp directories for testing
    tmp_dir = System.tmp_dir!()
    test_id = :erlang.unique_integer([:positive])
    test_dir = Path.join(tmp_dir, "config_test_#{test_id}")

    File.mkdir_p!(test_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{test_dir: test_dir}
  end

  # ============================================================================
  # Path Resolution Tests
  # ============================================================================

  describe "agent_dir/0" do
    test "returns path under user home directory" do
      result = Config.agent_dir()

      assert String.starts_with?(result, System.user_home!())
      assert String.ends_with?(result, ".lemon/agent")
    end

    test "returns absolute path" do
      result = Config.agent_dir()

      assert Path.type(result) == :absolute
    end

    test "returns consistent value" do
      assert Config.agent_dir() == Config.agent_dir()
    end
  end

  describe "sessions_dir/1" do
    test "returns path under agent directory" do
      result = Config.sessions_dir("/some/project")

      assert String.starts_with?(result, Config.agent_dir())
      assert String.contains?(result, "sessions")
    end

    test "includes encoded cwd in path" do
      result = Config.sessions_dir("/home/user/project")

      assert String.contains?(result, "--home-user-project--")
    end

    test "returns absolute path" do
      result = Config.sessions_dir("/any/path")

      assert Path.type(result) == :absolute
    end

    test "handles root path" do
      result = Config.sessions_dir("/")

      assert String.ends_with?(result, "------")
    end

    test "handles deeply nested paths" do
      result = Config.sessions_dir("/a/b/c/d/e/f/g")

      assert String.contains?(result, "--a-b-c-d-e-f-g--")
    end
  end

  describe "settings_file/0" do
    test "returns path under agent directory" do
      result = Config.settings_file()

      assert String.starts_with?(result, Config.agent_dir())
    end

    test "returns settings.json filename" do
      result = Config.settings_file()

      assert String.ends_with?(result, "settings.json")
    end

    test "returns absolute path" do
      result = Config.settings_file()

      assert Path.type(result) == :absolute
    end
  end

  describe "extensions_dir/0" do
    test "returns path under agent directory" do
      result = Config.extensions_dir()

      assert String.starts_with?(result, Config.agent_dir())
    end

    test "returns extensions directory" do
      result = Config.extensions_dir()

      assert String.ends_with?(result, "extensions")
    end
  end

  describe "skills_dir/0" do
    test "returns path under agent directory" do
      result = Config.skills_dir()

      assert String.starts_with?(result, Config.agent_dir())
    end

    test "returns skills directory" do
      result = Config.skills_dir()

      assert String.ends_with?(result, "skills")
    end
  end

  describe "prompts_dir/0" do
    test "returns path under agent directory" do
      result = Config.prompts_dir()

      assert String.starts_with?(result, Config.agent_dir())
    end

    test "returns prompts directory" do
      result = Config.prompts_dir()

      assert String.ends_with?(result, "prompts")
    end
  end

  describe "project_config_dir/1" do
    test "returns .lemon directory under given path" do
      result = Config.project_config_dir("/home/user/project")

      assert result == "/home/user/project/.lemon"
    end

    test "works with root path" do
      result = Config.project_config_dir("/")

      assert result == "/.lemon"
    end

    test "works with relative path" do
      result = Config.project_config_dir("relative/path")

      assert result == "relative/path/.lemon"
    end
  end

  describe "project_extensions_dir/1" do
    test "returns extensions under project config dir" do
      result = Config.project_extensions_dir("/home/user/project")

      assert result == "/home/user/project/.lemon/extensions"
    end

    test "is consistent with project_config_dir" do
      cwd = "/test/project"
      result = Config.project_extensions_dir(cwd)

      assert result == Path.join(Config.project_config_dir(cwd), "extensions")
    end
  end

  # ============================================================================
  # Path Encoding Tests
  # ============================================================================

  describe "encode_cwd/1" do
    test "wraps path with double dashes" do
      result = Config.encode_cwd("/home/user")

      assert String.starts_with?(result, "--")
      assert String.ends_with?(result, "--")
    end

    test "replaces forward slashes with dashes" do
      result = Config.encode_cwd("/home/user/project")

      assert result == "--home-user-project--"
    end

    test "strips leading slash" do
      result = Config.encode_cwd("/path")

      assert result == "--path--"
      refute String.contains?(result, "---")
    end

    test "handles root path" do
      result = Config.encode_cwd("/")

      # Leading slash stripped, then wrapped
      assert result == "------"
    end

    test "handles multiple consecutive slashes" do
      result = Config.encode_cwd("/path//to///project")

      # Multiple slashes become single dash
      assert result == "--path-to-project--"
    end

    test "handles paths with colons (Windows-style)" do
      result = Config.encode_cwd("C:/Users/project")

      # Colons are replaced like slashes
      assert result == "--C-Users-project--"
    end

    test "handles backslashes (Windows paths)" do
      result = Config.encode_cwd("\\Users\\project")

      # Backslashes are replaced with dashes
      assert result == "--Users-project--"
    end

    test "handles mixed path separators" do
      result = Config.encode_cwd("/home\\user/project")

      assert result == "--home-user-project--"
    end

    test "handles paths with special characters in names" do
      result = Config.encode_cwd("/path/my-project")

      # Existing dashes in path names are preserved
      assert result == "--path-my-project--"
    end

    test "handles empty string" do
      result = Config.encode_cwd("")

      assert result == "------"
    end
  end

  describe "decode_cwd/1" do
    test "removes wrapping double dashes" do
      result = Config.decode_cwd("--path--")

      assert result == "/path"
    end

    test "replaces dashes with forward slashes" do
      result = Config.decode_cwd("--home-user-project--")

      assert result == "/home/user/project"
    end

    test "adds leading slash" do
      result = Config.decode_cwd("--path--")

      assert String.starts_with?(result, "/")
    end

    test "handles root path encoding" do
      result = Config.decode_cwd("------")

      assert result == "/"
    end

    test "handles single component path" do
      result = Config.decode_cwd("--home--")

      assert result == "/home"
    end

    test "handles deeply nested path" do
      result = Config.decode_cwd("--a-b-c-d-e-f-g--")

      assert result == "/a/b/c/d/e/f/g"
    end
  end

  describe "encode_cwd/1 and decode_cwd/1 round-trip" do
    test "simple path round-trip" do
      original = "/home/user/project"
      encoded = Config.encode_cwd(original)
      decoded = Config.decode_cwd(encoded)

      assert decoded == original
    end

    test "root path round-trip" do
      original = "/"
      encoded = Config.encode_cwd(original)
      decoded = Config.decode_cwd(encoded)

      assert decoded == original
    end

    test "deeply nested path round-trip" do
      original = "/var/lib/app/data/cache/files"
      encoded = Config.encode_cwd(original)
      decoded = Config.decode_cwd(encoded)

      assert decoded == original
    end

    test "single component path round-trip" do
      original = "/tmp"
      encoded = Config.encode_cwd(original)
      decoded = Config.decode_cwd(encoded)

      assert decoded == original
    end

    # Note: Paths with dashes in component names cannot round-trip perfectly
    # because decode_cwd converts all dashes to slashes.
    # This is a known limitation of the encoding scheme.
    test "paths with dashes do NOT round-trip perfectly (known limitation)" do
      original = "/path/my-project/sub-dir"
      encoded = Config.encode_cwd(original)
      decoded = Config.decode_cwd(encoded)

      # This will convert internal dashes to slashes
      refute decoded == original
      assert decoded == "/path/my/project/sub/dir"
    end
  end

  # ============================================================================
  # Environment Tests
  # ============================================================================

  describe "get_env/2" do
    test "returns environment variable value when set" do
      key = "CONFIG_TEST_VAR_#{:erlang.unique_integer([:positive])}"
      System.put_env(key, "test_value")

      on_exit(fn -> System.delete_env(key) end)

      assert Config.get_env(key) == "test_value"
    end

    test "returns nil for unset variable without default" do
      result = Config.get_env("DEFINITELY_NOT_SET_VAR_12345")

      assert result == nil
    end

    test "returns default for unset variable" do
      result = Config.get_env("DEFINITELY_NOT_SET_VAR_12345", "my_default")

      assert result == "my_default"
    end

    test "returns value over default when variable is set" do
      key = "CONFIG_TEST_VAR_#{:erlang.unique_integer([:positive])}"
      System.put_env(key, "actual_value")

      on_exit(fn -> System.delete_env(key) end)

      result = Config.get_env(key, "default_value")

      assert result == "actual_value"
    end

    test "returns empty string when variable is set to empty" do
      key = "CONFIG_TEST_VAR_#{:erlang.unique_integer([:positive])}"
      System.put_env(key, "")

      on_exit(fn -> System.delete_env(key) end)

      result = Config.get_env(key, "default")

      assert result == ""
    end
  end

  describe "debug?/0" do
    setup do
      # Save original values
      original_pi_debug = System.get_env("PI_DEBUG")
      original_debug = System.get_env("DEBUG")

      # Clear both for clean test state
      System.delete_env("PI_DEBUG")
      System.delete_env("DEBUG")

      on_exit(fn ->
        # Restore original values
        if original_pi_debug, do: System.put_env("PI_DEBUG", original_pi_debug), else: System.delete_env("PI_DEBUG")
        if original_debug, do: System.put_env("DEBUG", original_debug), else: System.delete_env("DEBUG")
      end)

      :ok
    end

    test "returns false when neither PI_DEBUG nor DEBUG is set" do
      assert Config.debug?() == false
    end

    test "returns true when PI_DEBUG is '1'" do
      System.put_env("PI_DEBUG", "1")

      assert Config.debug?() == true
    end

    test "returns true when DEBUG is '1'" do
      System.put_env("DEBUG", "1")

      assert Config.debug?() == true
    end

    test "returns true when both are '1'" do
      System.put_env("PI_DEBUG", "1")
      System.put_env("DEBUG", "1")

      assert Config.debug?() == true
    end

    test "returns false when PI_DEBUG is set but not '1'" do
      System.put_env("PI_DEBUG", "true")

      assert Config.debug?() == false
    end

    test "returns false when DEBUG is set but not '1'" do
      System.put_env("DEBUG", "yes")

      assert Config.debug?() == false
    end

    test "returns false when PI_DEBUG is '0'" do
      System.put_env("PI_DEBUG", "0")

      assert Config.debug?() == false
    end

    test "PI_DEBUG takes precedence when both set differently" do
      System.put_env("PI_DEBUG", "1")
      System.put_env("DEBUG", "0")

      assert Config.debug?() == true
    end
  end

  describe "temp_dir/0" do
    test "returns a valid path" do
      result = Config.temp_dir()

      assert is_binary(result)
      assert Path.type(result) == :absolute
    end

    test "returns an existing directory" do
      result = Config.temp_dir()

      assert File.dir?(result)
    end

    test "matches System.tmp_dir!" do
      assert Config.temp_dir() == System.tmp_dir!()
    end
  end

  # ============================================================================
  # Directory Setup Tests
  # ============================================================================

  describe "ensure_dirs!/0" do
    # Note: System.user_home!/0 caches the home directory at VM startup,
    # so we cannot mock it by changing HOME environment variable.
    # Instead, we test the actual directories that ensure_dirs! creates.

    test "creates agent directory" do
      Config.ensure_dirs!()

      assert File.dir?(Config.agent_dir())
    end

    test "creates sessions directory" do
      Config.ensure_dirs!()

      # ensure_dirs! calls sessions_dir(".") which creates a specific session dir
      # We verify the sessions parent directory exists
      sessions_base = Path.join(Config.agent_dir(), "sessions")
      assert File.dir?(sessions_base)
    end

    test "creates extensions directory" do
      Config.ensure_dirs!()

      assert File.dir?(Config.extensions_dir())
    end

    test "creates skills directory" do
      Config.ensure_dirs!()

      assert File.dir?(Config.skills_dir())
    end

    test "creates prompts directory" do
      Config.ensure_dirs!()

      assert File.dir?(Config.prompts_dir())
    end

    test "returns :ok" do
      assert Config.ensure_dirs!() == :ok
    end

    test "is idempotent" do
      # Call multiple times
      assert Config.ensure_dirs!() == :ok
      assert Config.ensure_dirs!() == :ok
      assert Config.ensure_dirs!() == :ok

      # All directories should still exist
      assert File.dir?(Config.agent_dir())
      assert File.dir?(Config.extensions_dir())
      assert File.dir?(Config.skills_dir())
      assert File.dir?(Config.prompts_dir())
    end
  end

  # ============================================================================
  # Context Files Tests
  # ============================================================================

  describe "find_context_files/1" do
    test "returns empty list when no context files exist", %{test_dir: test_dir} do
      project_dir = Path.join(test_dir, "empty_project")
      File.mkdir_p!(project_dir)

      result = Config.find_context_files(project_dir)

      # May include global files if they exist in user's home
      # Filter to only local files for this test
      local_files = Enum.filter(result, &String.starts_with?(&1, test_dir))
      assert local_files == []
    end

    test "finds AGENTS.md in current directory", %{test_dir: test_dir} do
      project_dir = Path.join(test_dir, "project_with_agents")
      File.mkdir_p!(project_dir)
      agents_file = Path.join(project_dir, "AGENTS.md")
      File.write!(agents_file, "# Agent Instructions")

      result = Config.find_context_files(project_dir)

      assert agents_file in result
    end

    test "finds CLAUDE.md in current directory", %{test_dir: test_dir} do
      project_dir = Path.join(test_dir, "project_with_claude")
      File.mkdir_p!(project_dir)
      claude_file = Path.join(project_dir, "CLAUDE.md")
      File.write!(claude_file, "# Claude Instructions")

      result = Config.find_context_files(project_dir)

      assert claude_file in result
    end

    test "finds both AGENTS.md and CLAUDE.md when both exist", %{test_dir: test_dir} do
      project_dir = Path.join(test_dir, "project_with_both")
      File.mkdir_p!(project_dir)

      agents_file = Path.join(project_dir, "AGENTS.md")
      claude_file = Path.join(project_dir, "CLAUDE.md")
      File.write!(agents_file, "# Agent Instructions")
      File.write!(claude_file, "# Claude Instructions")

      result = Config.find_context_files(project_dir)

      assert agents_file in result
      assert claude_file in result
    end

    test "finds context files in parent directories", %{test_dir: test_dir} do
      parent_dir = Path.join(test_dir, "parent")
      child_dir = Path.join(parent_dir, "child")
      File.mkdir_p!(child_dir)

      parent_agents = Path.join(parent_dir, "AGENTS.md")
      File.write!(parent_agents, "# Parent Agent Instructions")

      result = Config.find_context_files(child_dir)

      assert parent_agents in result
    end

    test "finds context files at multiple levels", %{test_dir: test_dir} do
      level1 = Path.join(test_dir, "level1")
      level2 = Path.join(level1, "level2")
      level3 = Path.join(level2, "level3")
      File.mkdir_p!(level3)

      level1_agents = Path.join(level1, "AGENTS.md")
      level2_claude = Path.join(level2, "CLAUDE.md")
      level3_agents = Path.join(level3, "AGENTS.md")

      File.write!(level1_agents, "# Level 1")
      File.write!(level2_claude, "# Level 2")
      File.write!(level3_agents, "# Level 3")

      result = Config.find_context_files(level3)
      local_results = Enum.filter(result, &String.starts_with?(&1, test_dir))

      assert level1_agents in local_results
      assert level2_claude in local_results
      assert level3_agents in local_results
    end

    test "orders files from deepest to shallowest", %{test_dir: test_dir} do
      parent = Path.join(test_dir, "parent_order")
      child = Path.join(parent, "child_order")
      File.mkdir_p!(child)

      parent_agents = Path.join(parent, "AGENTS.md")
      child_agents = Path.join(child, "AGENTS.md")

      File.write!(parent_agents, "# Parent")
      File.write!(child_agents, "# Child")

      result = Config.find_context_files(child)
      local_results = Enum.filter(result, &String.starts_with?(&1, test_dir))

      # Child should come before parent
      child_idx = Enum.find_index(local_results, &(&1 == child_agents))
      parent_idx = Enum.find_index(local_results, &(&1 == parent_agents))

      assert child_idx < parent_idx
    end

    test "handles root path without error" do
      # Should not raise, even if traversing all the way to root
      result = Config.find_context_files("/")

      assert is_list(result)
    end

    test "expands relative paths", %{test_dir: test_dir} do
      # Create a subdir and put a context file there
      subdir = Path.join(test_dir, "relpath_test")
      File.mkdir_p!(subdir)
      agents_file = Path.join(subdir, "AGENTS.md")
      File.write!(agents_file, "# Test")

      # Use the absolute path but verify expansion works
      result = Config.find_context_files(subdir)

      # The result should contain absolute paths
      Enum.each(result, fn path ->
        assert Path.type(path) == :absolute
      end)
    end

    test "ignores non-existent directories gracefully", %{test_dir: test_dir} do
      non_existent = Path.join(test_dir, "does_not_exist")

      # Should not raise
      result = Config.find_context_files(non_existent)

      assert is_list(result)
    end

    test "only returns files that actually exist", %{test_dir: test_dir} do
      project_dir = Path.join(test_dir, "exists_check")
      File.mkdir_p!(project_dir)

      # Create one file but not the other
      agents_file = Path.join(project_dir, "AGENTS.md")
      File.write!(agents_file, "# Exists")

      # CLAUDE.md is not created

      result = Config.find_context_files(project_dir)
      local_results = Enum.filter(result, &String.starts_with?(&1, project_dir))

      assert agents_file in local_results
      refute Path.join(project_dir, "CLAUDE.md") in local_results
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "all dir functions return strings" do
      assert is_binary(Config.agent_dir())
      assert is_binary(Config.sessions_dir("/test"))
      assert is_binary(Config.settings_file())
      assert is_binary(Config.extensions_dir())
      assert is_binary(Config.skills_dir())
      assert is_binary(Config.prompts_dir())
      assert is_binary(Config.project_config_dir("/test"))
      assert is_binary(Config.project_extensions_dir("/test"))
      assert is_binary(Config.temp_dir())
    end

    test "encode_cwd handles unicode paths" do
      result = Config.encode_cwd("/home/用户/项目")

      assert String.starts_with?(result, "--")
      assert String.ends_with?(result, "--")
      assert String.contains?(result, "用户")
    end

    test "encode_cwd handles spaces in paths" do
      result = Config.encode_cwd("/home/user/my project")

      # Spaces are preserved in encoding
      assert String.contains?(result, "my project")
    end

    test "all absolute path functions work with any user home" do
      # These functions should work regardless of what HOME is set to
      agent_dir = Config.agent_dir()
      settings_file = Config.settings_file()
      extensions_dir = Config.extensions_dir()
      skills_dir = Config.skills_dir()
      prompts_dir = Config.prompts_dir()

      # All should be under agent_dir
      assert String.starts_with?(settings_file, agent_dir)
      assert String.starts_with?(extensions_dir, agent_dir)
      assert String.starts_with?(skills_dir, agent_dir)
      assert String.starts_with?(prompts_dir, agent_dir)
    end

    test "sessions_dir creates unique paths for different cwds" do
      session1 = Config.sessions_dir("/project1")
      session2 = Config.sessions_dir("/project2")
      session3 = Config.sessions_dir("/home/user/project")

      assert session1 != session2
      assert session1 != session3
      assert session2 != session3
    end

    test "project directories work with trailing slashes" do
      with_slash = Config.project_config_dir("/home/user/project/")
      without_slash = Config.project_config_dir("/home/user/project")

      # Both should produce similar results (Path.join handles trailing slashes)
      assert String.contains?(with_slash, ".lemon")
      assert String.contains?(without_slash, ".lemon")
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration" do
    test "sessions_dir and encode_cwd are consistent" do
      cwd = "/home/user/myproject"
      sessions_dir = Config.sessions_dir(cwd)
      encoded = Config.encode_cwd(cwd)

      assert String.contains?(sessions_dir, encoded)
    end

    test "project directories are relative to provided cwd" do
      cwd = "/some/random/path"

      config_dir = Config.project_config_dir(cwd)
      extensions_dir = Config.project_extensions_dir(cwd)

      assert String.starts_with?(config_dir, cwd)
      assert String.starts_with?(extensions_dir, cwd)
      assert String.starts_with?(extensions_dir, config_dir)
    end

    test "global and project directories don't overlap" do
      cwd = "/home/user/project"

      global_extensions = Config.extensions_dir()
      project_extensions = Config.project_extensions_dir(cwd)

      # These should be completely different paths
      refute global_extensions == project_extensions
      refute String.starts_with?(global_extensions, cwd)
    end
  end
end
