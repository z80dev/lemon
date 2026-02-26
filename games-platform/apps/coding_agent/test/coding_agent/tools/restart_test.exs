defmodule CodingAgent.Tools.RestartTest do
  # Mutates process environment; run serially.
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.Restart

  setup do
    original = System.get_env("LEMON_ALLOW_RESTART_TOOL")

    on_exit(fn ->
      if original do
        System.put_env("LEMON_ALLOW_RESTART_TOOL", original)
      else
        System.delete_env("LEMON_ALLOW_RESTART_TOOL")
      end
    end)

    :ok
  end

  describe "tool/2" do
    test "returns an AgentTool struct with restart metadata" do
      tool = Restart.tool("/tmp")

      assert tool.name == "restart"
      assert tool.label == "Restart Agent"
      assert tool.description =~ "Restart the Lemon agent process"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == []
      assert Map.has_key?(tool.parameters["properties"], "reason")
      assert Map.has_key?(tool.parameters["properties"], "confirm")
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/5" do
    test "denies restart outside debug UI and without override env var" do
      System.delete_env("LEMON_ALLOW_RESTART_TOOL")

      result = Restart.execute("call_1", %{}, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Restart is only supported"
      assert details == %{restarted: false, denied: true}
    end

    test "handles reason/confirm params and still denies in non-debug context" do
      System.delete_env("LEMON_ALLOW_RESTART_TOOL")

      result =
        Restart.execute(
          "call_1",
          %{"reason" => "  reload after config change  ", "confirm" => false},
          nil,
          nil,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Restart is only supported"
      assert details.restarted == false
      assert details.denied == true
    end
  end
end
