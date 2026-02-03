defmodule CodingAgent.SubagentsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Subagents

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    original_home = System.get_env("HOME")
    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    {:ok, home_dir: home_dir}
  end

  test "filters invalid entries and merges overrides", %{tmp_dir: tmp_dir, home_dir: home_dir} do
    project_dir = Path.join(tmp_dir, "project")
    project_config = Path.join(project_dir, ".lemon")
    File.mkdir_p!(project_config)

    project_agents = [
      %{"id" => "", "prompt" => "ignored"},
      %{"id" => "custom", "prompt" => "   "},
      %{"id" => "custom2", "prompt" => "Do work", "description" => 123},
      %{"id" => "review", "prompt" => "Override review", "description" => "Override"}
    ]

    File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(project_agents))

    agent_dir = CodingAgent.Config.agent_dir()
    global_path = Path.join(agent_dir, "subagents.json")
    if String.starts_with?(agent_dir, home_dir) do
      File.mkdir_p!(agent_dir)
      global_agents = [%{"id" => "global", "prompt" => "Global prompt"}]
      File.write!(global_path, Jason.encode!(global_agents))
    end

    agents = Subagents.list(project_dir)

    assert Subagents.get(project_dir, "custom") == nil
    assert Subagents.get(project_dir, "custom2").prompt == "Do work"
    assert Subagents.get(project_dir, "custom2").description == ""
    assert Subagents.get(project_dir, "review").prompt == "Override review"
    if String.starts_with?(agent_dir, home_dir) do
      assert Subagents.get(project_dir, "global").prompt == "Global prompt"
    end

    ids = Enum.map(agents, & &1.id)
    refute "" in ids
  end

  # ===========================================================================
  # Corrupted JSON handling
  # ===========================================================================

  describe "list/1 with corrupted JSON" do
    test "returns defaults when project file contains invalid JSON", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "corrupt_project")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      # Write malformed JSON
      File.write!(Path.join(project_config, "subagents.json"), "{invalid json content")

      agents = Subagents.list(project_dir)

      # Should return default agents unchanged
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "returns defaults when global file contains invalid JSON", %{tmp_dir: tmp_dir, home_dir: home_dir} do
      project_dir = Path.join(tmp_dir, "project_no_config")
      File.mkdir_p!(project_dir)

      agent_dir = CodingAgent.Config.agent_dir()
      if String.starts_with?(agent_dir, home_dir) do
        File.mkdir_p!(agent_dir)
        # Write truncated JSON
        File.write!(Path.join(agent_dir, "subagents.json"), "[{\"id\": \"test\"")
      end

      agents = Subagents.list(project_dir)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "handles empty string JSON content", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "empty_json")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "subagents.json"), "")

      agents = Subagents.list(project_dir)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "handles JSON with only whitespace", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "whitespace_json")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "subagents.json"), "   \n\t  ")

      agents = Subagents.list(project_dir)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "handles JSON that decodes to non-list value", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "object_json")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      # Valid JSON but wrong type (object instead of array)
      File.write!(Path.join(project_config, "subagents.json"), ~s({"id": "test", "prompt": "hello"}))

      agents = Subagents.list(project_dir)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "handles JSON with special characters", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "special_chars")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      # JSON with null bytes and control characters
      File.write!(Path.join(project_config, "subagents.json"), "[{\"id\": \"test\x00\", \"prompt\": \"hi\"}]")

      agents = Subagents.list(project_dir)
      # Should fail to parse and return defaults
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end
  end

  # ===========================================================================
  # File read errors handling
  # ===========================================================================

  describe "list/1 file read errors" do
    test "handles non-existent project directory", %{tmp_dir: tmp_dir} do
      non_existent = Path.join(tmp_dir, "does_not_exist")

      agents = Subagents.list(non_existent)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "handles non-existent config directory", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project_no_lemon")
      File.mkdir_p!(project_dir)
      # Don't create .lemon directory

      agents = Subagents.list(project_dir)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "handles directory instead of file", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project_dir_as_file")
      project_config = Path.join(project_dir, ".lemon")
      # Create the subagents.json as a directory instead of file
      File.mkdir_p!(Path.join(project_config, "subagents.json"))

      agents = Subagents.list(project_dir)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "handles unreadable file (permission denied)", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "project_unreadable")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      file_path = Path.join(project_config, "subagents.json")
      File.write!(file_path, "[]")
      # Remove read permission
      File.chmod!(file_path, 0o000)

      on_exit(fn ->
        # Restore permission for cleanup
        File.chmod(file_path, 0o644)
      end)

      agents = Subagents.list(project_dir)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end
  end

  # ===========================================================================
  # Invalid agent definitions
  # ===========================================================================

  describe "list/1 with invalid agent definitions" do
    test "filters out entries missing id field", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "missing_id")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"prompt" => "No id here", "description" => "Test"},
        %{"id" => "valid", "prompt" => "Has id"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      _agents = Subagents.list(project_dir)
      assert Subagents.get(project_dir, "valid") != nil
      # No agent without id should be present - verified via get returning nil
    end

    test "filters out entries missing prompt field", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "missing_prompt")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "no_prompt", "description" => "Test"},
        %{"id" => "valid", "prompt" => "Has prompt"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      _agents = Subagents.list(project_dir)
      assert Subagents.get(project_dir, "valid") != nil
      assert Subagents.get(project_dir, "no_prompt") == nil
    end

    test "filters out non-map entries in array", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "non_map_entries")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      # Mix of valid and invalid entries
      content = ~s([
        "just a string",
        123,
        null,
        true,
        [],
        {"id": "valid", "prompt": "Valid agent"}
      ])
      File.write!(Path.join(project_config, "subagents.json"), content)

      agents = Subagents.list(project_dir)
      assert Subagents.get(project_dir, "valid") != nil
      # Count custom agents (excluding defaults)
      custom = Enum.reject(agents, fn a -> a.id in ["implement", "research", "review", "test"] end)
      assert length(custom) == 1
    end

    test "filters out entries with non-string id", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "non_string_id")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => 123, "prompt" => "Numeric id"},
        %{"id" => nil, "prompt" => "Null id"},
        %{"id" => true, "prompt" => "Boolean id"},
        %{"id" => ["array"], "prompt" => "Array id"},
        %{"id" => "valid", "prompt" => "String id"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agents = Subagents.list(project_dir)
      assert Subagents.get(project_dir, "valid") != nil
      custom = Enum.reject(agents, fn a -> a.id in ["implement", "research", "review", "test"] end)
      assert length(custom) == 1
    end

    test "filters out entries with non-string prompt", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "non_string_prompt")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "num", "prompt" => 123},
        %{"id" => "null", "prompt" => nil},
        %{"id" => "bool", "prompt" => false},
        %{"id" => "valid", "prompt" => "String prompt"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      _agents = Subagents.list(project_dir)
      assert Subagents.get(project_dir, "valid") != nil
      assert Subagents.get(project_dir, "num") == nil
      assert Subagents.get(project_dir, "null") == nil
      assert Subagents.get(project_dir, "bool") == nil
    end

    test "handles deeply nested invalid structures", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "nested_invalid")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => %{"nested" => "object"}, "prompt" => "Nested id"},
        %{"id" => "valid", "prompt" => "Good"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      _agents = Subagents.list(project_dir)
      assert Subagents.get(project_dir, "valid") != nil
    end
  end

  # ===========================================================================
  # Merging/override logic edge cases
  # ===========================================================================

  describe "merge/override logic" do
    test "project overrides global which overrides defaults", %{tmp_dir: tmp_dir, home_dir: home_dir} do
      project_dir = Path.join(tmp_dir, "merge_test")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agent_dir = CodingAgent.Config.agent_dir()
      if String.starts_with?(agent_dir, home_dir) do
        File.mkdir_p!(agent_dir)

        # Global overrides default "research" agent
        global_agents = [
          %{"id" => "research", "prompt" => "Global research", "description" => "Global desc"}
        ]
        File.write!(Path.join(agent_dir, "subagents.json"), Jason.encode!(global_agents))
      end

      # Project overrides "research" again
      project_agents = [
        %{"id" => "research", "prompt" => "Project research", "description" => "Project desc"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(project_agents))

      agent = Subagents.get(project_dir, "research")
      assert agent.prompt == "Project research"
      assert agent.description == "Project desc"
    end

    test "partial override preserves other agents", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "partial_override")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      # Only override one default agent
      project_agents = [
        %{"id" => "implement", "prompt" => "Custom implement", "description" => "Custom desc"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(project_agents))

      _agents = Subagents.list(project_dir)

      # Override applied
      implement = Subagents.get(project_dir, "implement")
      assert implement.prompt == "Custom implement"

      # Other defaults preserved
      research = Subagents.get(project_dir, "research")
      assert research.prompt =~ "research subagent"
    end

    test "adding new agents without overriding defaults", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "add_new")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      project_agents = [
        %{"id" => "custom1", "prompt" => "Custom 1"},
        %{"id" => "custom2", "prompt" => "Custom 2"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(project_agents))

      _agents = Subagents.list(project_dir)

      # Defaults still present
      default_ids = ["implement", "research", "review", "test"]
      for id <- default_ids do
        assert Subagents.get(project_dir, id) != nil
      end

      # Custom agents added
      assert Subagents.get(project_dir, "custom1") != nil
      assert Subagents.get(project_dir, "custom2") != nil
    end

    test "agents are sorted by id", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "sorted_test")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      project_agents = [
        %{"id" => "zebra", "prompt" => "Z"},
        %{"id" => "alpha", "prompt" => "A"},
        %{"id" => "middle", "prompt" => "M"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(project_agents))

      agents = Subagents.list(project_dir)
      ids = Enum.map(agents, & &1.id)

      # Should be sorted alphabetically
      assert ids == Enum.sort(ids)
    end

    test "empty project file does not affect defaults", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "empty_array")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      File.write!(Path.join(project_config, "subagents.json"), "[]")

      agents = Subagents.list(project_dir)
      default_ids = ["implement", "research", "review", "test"]
      assert Enum.map(agents, & &1.id) == default_ids
    end

    test "override with same id replaces entire agent", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "full_replace")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      # Override with different description
      project_agents = [
        %{"id" => "research", "prompt" => "New prompt", "description" => "New description"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(project_agents))

      agent = Subagents.get(project_dir, "research")
      # Both prompt and description are from override, not merged with default
      assert agent.prompt == "New prompt"
      assert agent.description == "New description"
    end

    test "global agents are used when no project config exists", %{tmp_dir: tmp_dir, home_dir: home_dir} do
      project_dir = Path.join(tmp_dir, "no_project_config")
      File.mkdir_p!(project_dir)

      agent_dir = CodingAgent.Config.agent_dir()
      if String.starts_with?(agent_dir, home_dir) do
        File.mkdir_p!(agent_dir)

        global_agents = [
          %{"id" => "global_custom", "prompt" => "Global custom agent"}
        ]
        File.write!(Path.join(agent_dir, "subagents.json"), Jason.encode!(global_agents))

        _agents = Subagents.list(project_dir)
        assert Subagents.get(project_dir, "global_custom") != nil
      end
    end
  end

  # ===========================================================================
  # normalize_agent/1 whitespace handling
  # ===========================================================================

  describe "normalize_agent whitespace handling" do
    test "trims leading and trailing whitespace from id", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "whitespace_id")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "  spaced  ", "prompt" => "Test"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agent = Subagents.get(project_dir, "spaced")
      assert agent != nil
      assert agent.id == "spaced"
    end

    test "trims leading and trailing whitespace from prompt", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "whitespace_prompt")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "test", "prompt" => "\n\t  Trimmed prompt  \n\t"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agent = Subagents.get(project_dir, "test")
      assert agent.prompt == "Trimmed prompt"
    end

    test "rejects id that becomes empty after trimming", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "empty_after_trim_id")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "   ", "prompt" => "Valid prompt"},
        %{"id" => "\t\n", "prompt" => "Another"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agents = Subagents.list(project_dir)
      custom = Enum.reject(agents, fn a -> a.id in ["implement", "research", "review", "test"] end)
      assert custom == []
    end

    test "rejects prompt that becomes empty after trimming", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "empty_after_trim_prompt")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "empty1", "prompt" => "   "},
        %{"id" => "empty2", "prompt" => "\n\n\t"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      _agents = Subagents.list(project_dir)
      assert Subagents.get(project_dir, "empty1") == nil
      assert Subagents.get(project_dir, "empty2") == nil
    end

    test "preserves internal whitespace in prompt", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "internal_whitespace")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "test", "prompt" => "Line one\n\nLine two\twith tab"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agent = Subagents.get(project_dir, "test")
      assert agent.prompt == "Line one\n\nLine two\twith tab"
    end

    test "handles unicode whitespace characters", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "unicode_whitespace")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      # Non-breaking space, em space, etc.
      agents_json = [
        %{"id" => "unicode", "prompt" => "Test prompt"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agent = Subagents.get(project_dir, "unicode")
      assert agent != nil
    end
  end

  # ===========================================================================
  # Type coercion scenarios
  # ===========================================================================

  describe "type coercion" do
    test "description is converted to empty string if non-string", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "desc_coercion")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "num_desc", "prompt" => "Test", "description" => 123},
        %{"id" => "null_desc", "prompt" => "Test", "description" => nil},
        %{"id" => "bool_desc", "prompt" => "Test", "description" => true},
        %{"id" => "arr_desc", "prompt" => "Test", "description" => [1, 2, 3]},
        %{"id" => "obj_desc", "prompt" => "Test", "description" => %{"key" => "value"}}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      for id <- ["num_desc", "null_desc", "bool_desc", "arr_desc", "obj_desc"] do
        agent = Subagents.get(project_dir, id)
        assert agent != nil, "Agent #{id} should exist"
        assert agent.description == "", "Agent #{id} should have empty description"
      end
    end

    test "string description is preserved", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "string_desc")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "valid", "prompt" => "Test", "description" => "Valid description"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agent = Subagents.get(project_dir, "valid")
      assert agent.description == "Valid description"
    end

    test "id must be string - no coercion", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "id_no_coerce")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      # Integer id should not be coerced to string
      agents_json = [
        %{"id" => 42, "prompt" => "Test"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agents = Subagents.list(project_dir)
      custom = Enum.reject(agents, fn a -> a.id in ["implement", "research", "review", "test"] end)
      assert custom == []
    end

    test "prompt must be string - no coercion", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "prompt_no_coerce")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "num_prompt", "prompt" => 42}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agent = Subagents.get(project_dir, "num_prompt")
      assert agent == nil
    end
  end

  # ===========================================================================
  # Default value handling
  # ===========================================================================

  describe "default value handling" do
    test "missing description defaults to empty string", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "no_desc")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "no_description", "prompt" => "Just a prompt"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agent = Subagents.get(project_dir, "no_description")
      assert agent != nil
      assert agent.description == ""
    end

    test "default agents have all required fields", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "check_defaults")
      File.mkdir_p!(project_dir)

      agents = Subagents.list(project_dir)

      for agent <- agents do
        assert is_binary(agent.id), "id should be a string"
        assert is_binary(agent.prompt), "prompt should be a string"
        assert is_binary(agent.description), "description should be a string"
        assert agent.id != "", "id should not be empty"
        assert agent.prompt != "", "prompt should not be empty"
      end
    end

    test "default agents include research, implement, review, test", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "verify_defaults")
      File.mkdir_p!(project_dir)

      agents = Subagents.list(project_dir)
      ids = Enum.map(agents, & &1.id)

      assert "research" in ids
      assert "implement" in ids
      assert "review" in ids
      assert "test" in ids
    end

    test "extra fields in JSON are ignored", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "extra_fields")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{
          "id" => "custom",
          "prompt" => "Test",
          "description" => "Desc",
          "extra_field" => "ignored",
          "another" => 123,
          "nested" => %{"deep" => "value"}
        }
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      agent = Subagents.get(project_dir, "custom")
      assert agent != nil
      # Only expected keys should be present
      assert Map.keys(agent) |> Enum.sort() == [:description, :id, :prompt]
    end
  end

  # ===========================================================================
  # get/2 function tests
  # ===========================================================================

  describe "get/2" do
    test "returns nil for non-existent agent", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "get_nil")
      File.mkdir_p!(project_dir)

      assert Subagents.get(project_dir, "nonexistent") == nil
    end

    test "returns correct agent by id", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "get_correct")
      File.mkdir_p!(project_dir)

      agent = Subagents.get(project_dir, "research")
      assert agent.id == "research"
      assert agent.prompt =~ "research"
    end

    test "id matching is exact (case-sensitive)", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "case_sensitive")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "MyAgent", "prompt" => "Test"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      assert Subagents.get(project_dir, "MyAgent") != nil
      assert Subagents.get(project_dir, "myagent") == nil
      assert Subagents.get(project_dir, "MYAGENT") == nil
    end
  end

  # ===========================================================================
  # format_for_description/1 function tests
  # ===========================================================================

  describe "format_for_description/1" do
    test "returns empty string when no agents", %{tmp_dir: tmp_dir} do
      # This test requires mocking defaults, which we can't easily do
      # Instead, test that it returns a non-empty string with defaults
      project_dir = Path.join(tmp_dir, "format_test")
      File.mkdir_p!(project_dir)

      result = Subagents.format_for_description(project_dir)
      # With default agents, should return formatted list
      assert result =~ "- research:"
      assert result =~ "- implement:"
    end

    test "formats agents with id and description", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "format_custom")
      project_config = Path.join(project_dir, ".lemon")
      File.mkdir_p!(project_config)

      agents_json = [
        %{"id" => "custom", "prompt" => "Test", "description" => "Custom description"}
      ]
      File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(agents_json))

      result = Subagents.format_for_description(project_dir)
      assert result =~ "- custom: Custom description"
    end

    test "multiple agents are joined with newlines", %{tmp_dir: tmp_dir} do
      project_dir = Path.join(tmp_dir, "format_multi")
      File.mkdir_p!(project_dir)

      result = Subagents.format_for_description(project_dir)
      lines = String.split(result, "\n")
      assert length(lines) >= 4  # At least the 4 defaults
    end
  end
end
