defmodule CodingAgentTest do
  use ExUnit.Case, async: true

  describe "coding_tools/2" do
    test "returns list of 14 tools" do
      tools = CodingAgent.coding_tools("/tmp")
      assert length(tools) == 14
      assert Enum.all?(tools, &match?(%AgentCore.Types.AgentTool{}, &1))
    end

    test "tools have correct names" do
      tools = CodingAgent.coding_tools("/tmp")
      names = Enum.map(tools, & &1.name)
      assert "browser" in names
      assert "read" in names
      assert "write" in names
      assert "edit" in names
      assert "patch" in names
      assert "bash" in names
      assert "grep" in names
      assert "find" in names
      assert "ls" in names
      assert "webfetch" in names
      assert "websearch" in names
      assert "todo" in names
      assert "task" in names
      assert "extensions_status" in names
    end
  end

  describe "read_only_tools/2" do
    test "returns list with exploration tools" do
      tools = CodingAgent.read_only_tools("/tmp")
      assert length(tools) == 4
      names = Enum.map(tools, & &1.name)
      assert "read" in names
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
      assert settings.reserve_tokens == 16384
    end
  end
end
