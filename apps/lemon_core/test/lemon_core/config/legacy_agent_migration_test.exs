defmodule LemonCore.Config.LegacyAgentMigrationTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.LegacyAgentMigration

  # Byte-for-byte what the 2026.10.2 TUI wrote after "make default" in the
  # model picker on a fresh install configured for ChatGPT (openai-codex).
  @tui_written """
  [agent]
  default_provider = "openai"
  default_model = "openai:gpt-5.1"

  [control_plane]

  [providers."anthropic"]
  api_key_secret = "anthropic_api_key"

  [providers."openai-codex"]
  oauth_secret = "llm_openai_codex_api_key"
  auth_source = "oauth"
  """

  describe "migrate_settings/1" do
    test "maps defaults, theme and runtime keys" do
      settings = %{
        "agent" => %{
          "default_provider" => "openai",
          "default_model" => "openai:gpt-5.1",
          "default_thinking_level" => "high",
          "theme" => "light",
          "max_tool_turns" => 40,
          "compaction" => %{"enabled" => false}
        }
      }

      assert LegacyAgentMigration.migrate_settings(settings) == %{
               "defaults" => %{
                 "provider" => "openai",
                 "model" => "openai:gpt-5.1",
                 "thinking_level" => "high"
               },
               "tui" => %{"theme" => "light"},
               "runtime" => %{"max_tool_turns" => 40, "compaction" => %{"enabled" => false}}
             }
    end

    test "existing [defaults] and [runtime] values win over legacy ones" do
      settings = %{
        "agent" => %{
          "default_model" => "legacy",
          "max_tool_turns" => 1,
          "compaction" => %{"enabled" => false, "reserve_tokens" => 1}
        },
        "defaults" => %{"model" => "current"},
        "runtime" => %{"max_tool_turns" => 9, "compaction" => %{"enabled" => true}},
        "tui" => %{"theme" => "lemon", "debug" => true}
      }

      assert LegacyAgentMigration.migrate_settings(settings) == %{
               "defaults" => %{"model" => "current"},
               "runtime" => %{
                 "max_tool_turns" => 9,
                 "compaction" => %{"enabled" => true, "reserve_tokens" => 1}
               },
               "tui" => %{"theme" => "lemon", "debug" => true}
             }
    end

    test "leaves settings without an [agent] table alone" do
      settings = %{"defaults" => %{"model" => "x"}, "agent" => "scalar"}
      assert LegacyAgentMigration.migrate_settings(settings) == settings
    end
  end

  describe "migrate_content/1" do
    test "long quoted dotted keys migrate without overlapping regex alternatives" do
      key = Enum.map_join(1..100, ".", fn _ -> ~s("a") end)
      content = "[agent]\n" <> key <> " = true\n"
      assert {:ok, migrated, _} = LegacyAgentMigration.migrate_content(content)
      assert {:ok, decoded} = Toml.decode(migrated)
      assert decoded["runtime"] == elem(Toml.decode(content), 1)["agent"]
    end

    test "rewrites the TUI-written file to the current schema" do
      assert {:ok, migrated, changes} = LegacyAgentMigration.migrate_content(@tui_written)

      assert migrated == """
             [control_plane]

             [providers."anthropic"]
             api_key_secret = "anthropic_api_key"

             [providers."openai-codex"]
             oauth_secret = "llm_openai_codex_api_key"
             auth_source = "oauth"

             [defaults]
             provider = "openai"
             model = "openai:gpt-5.1"
             """

      assert changes == [
               "agent.default_provider → defaults.provider",
               "agent.default_model → defaults.model"
             ]

      assert {:ok, decoded} = Toml.decode(migrated)
      assert {:ok, _config} = LemonCore.Config.Modular.validate_settings(decoded)
      refute Map.has_key?(decoded, "agent")
    end

    test "keeps comments and unrelated tables and moves nested tables to [runtime]" do
      content = """
      # top comment
      [defaults]
      provider = "anthropic"

      [agent]
      # legacy block
      default_model = "anthropic:claude" # trailing note
      theme = "dark"
      max_tool_turns = 12

      [agent.compaction]
      enabled = false

      [gateway]
      max_concurrent_runs = 2
      """

      assert {:ok, migrated, _changes} = LegacyAgentMigration.migrate_content(content)

      assert migrated =~ "# top comment"
      assert migrated =~ "# legacy block"
      assert migrated =~ ~s(model = "anthropic:claude" # trailing note)
      assert migrated =~ "[runtime.compaction]\nenabled = false"
      refute migrated =~ "[agent"

      assert {:ok, decoded} = Toml.decode(migrated)

      assert decoded == %{
               "defaults" => %{"provider" => "anthropic", "model" => "anthropic:claude"},
               "tui" => %{"theme" => "dark"},
               "runtime" => %{"max_tool_turns" => 12, "compaction" => %{"enabled" => false}},
               "gateway" => %{"max_concurrent_runs" => 2}
             }
    end

    test "drops legacy defaults already overridden by [defaults]" do
      content = """
      [defaults]
      model = "current"

      [agent]
      default_model = "legacy"
      """

      assert {:ok, migrated, ["agent.default_model dropped: defaults.model is already set"]} =
               LegacyAgentMigration.migrate_content(content)

      assert Toml.decode(migrated) == {:ok, %{"defaults" => %{"model" => "current"}}}
    end

    test "is :unchanged without an [agent] table" do
      assert :unchanged = LegacyAgentMigration.migrate_content("[defaults]\nmodel = \"x\"\n")
    end

    test "refuses multi-line values inside [agent]" do
      content = """
      [agent]
      extension_paths = [
        "a",
      ]
      """

      assert {:error, :unsupported_layout} = LegacyAgentMigration.migrate_content(content)
    end

    test "refuses when a renamed table would collide with an existing one" do
      content = """
      [agent.compaction]
      enabled = false

      [runtime.compaction]
      enabled = true
      """

      assert {:error, :verification_failed} = LegacyAgentMigration.migrate_content(content)
    end

    test "reports invalid TOML" do
      assert {:error, {:invalid_toml, _}} = LegacyAgentMigration.migrate_content("[agent\n")
    end
  end
end
