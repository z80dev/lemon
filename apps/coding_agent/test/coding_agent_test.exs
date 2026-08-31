defmodule CodingAgentTest do
  use ExUnit.Case, async: true

  describe "coding_tools/2" do
    # Pins the platform's own 59 builtins. Satellite tools (x_api, lemon_honcho)
    # register through LemonAgent.ToolRegistry when their app happens to be
    # running in the test VM — umbrella-root runs boot them, per-app CI lanes
    # may not — so they are subtracted rather than counted. Satellite
    # contribution/precedence is covered by tool_precedence_test.exs.
    test "returns list of 59 builtin tools plus registered extras" do
      tools = CodingAgent.coding_tools("/tmp")

      registered =
        MapSet.new(LemonAgent.ToolRegistry.all(), fn {name, _} -> Atom.to_string(name) end)

      builtins = Enum.reject(tools, &MapSet.member?(registered, &1.name))
      assert length(builtins) == 59
      assert Enum.all?(tools, &match?(%LemonAgent.Types.AgentTool{}, &1))
    end

    test "tools have correct names" do
      tools = CodingAgent.coding_tools("/tmp")
      names = Enum.map(tools, & &1.name)
      assert "read" in names
      assert "write" in names
      assert "edit" in names
      assert "patch" in names
      assert "lsp_diagnostics" in names
      assert "bash" in names
      assert "grep" in names
      assert "find" in names
      assert "ls" in names
      assert "read_skill" in names
      assert "skill_manage" in names
      assert "memory_topic" in names
      assert "memory" in names
      assert "search_memory" in names
      assert "session_search" in names
      assert "checkpoint" in names
      assert "webfetch" in names
      assert "websearch" in names
      assert "browser_navigate" in names
      assert "browser_snapshot" in names
      assert "browser_get_content" in names
      assert "browser_click" in names
      assert "browser_type" in names
      assert "browser_hover" in names
      assert "browser_select_option" in names
      assert "browser_upload_file" in names
      assert "browser_download" in names
      assert "browser_press" in names
      assert "browser_scroll" in names
      assert "browser_back" in names
      assert "browser_wait_for_selector" in names
      assert "browser_evaluate" in names
      assert "browser_events" in names
      assert "browser_get_cookies" in names
      assert "browser_set_cookies" in names
      assert "browser_clear_state" in names
      assert "browser_screenshot" in names
      assert "media_status" in names
      assert "media_generate_image" in names
      assert "media_generate_speech" in names
      assert "media_transcribe_audio" in names
      assert "media_analyze_image" in names
      assert "media_generate_video" in names
      assert "todo" in names
      assert "kanban" in names
      assert "peer" in names
      assert "task" in names
      assert "agent" in names
      assert "parent_question" in names
      assert "tool_auth" in names
      assert "extensions_status" in names
    end
  end

  describe "read_only_tools/2" do
    test "returns list with exploration tools" do
      tools = CodingAgent.read_only_tools("/tmp")
      assert length(tools) == 7
      names = Enum.map(tools, & &1.name)
      assert "read" in names
      assert "read_skill" in names
      assert "search_memory" in names
      assert "session_search" in names
      assert "grep" in names
      assert "find" in names
      assert "ls" in names
    end
  end

  describe "load_settings/1" do
    test "returns SettingsManager struct" do
      settings = CodingAgent.load_settings("/tmp")
      assert %CodingAgent.SettingsManager{} = settings
    end

    test "has default compaction settings" do
      settings = CodingAgent.load_settings("/tmp")
      assert settings.compaction_enabled == true
      assert settings.reserve_tokens == 16_384
    end
  end
end
