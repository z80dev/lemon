defmodule LemonRouter.ToolStatusRendererTest do
  use ExUnit.Case, async: true

  alias LemonRouter.ToolStatusRenderer

  test "renders tool result preview without Elixir struct noise" do
    inspected =
      "%AgentCore.Types.AgentToolResult{content: [%Ai.Types.TextContent{type: :text, text: \"hello\\nworld\"}]}"

    actions = %{
      "a1" => %{
        title: "Test tool",
        phase: :completed,
        ok: true,
        detail: %{result_preview: inspected}
      }
    }

    text = ToolStatusRenderer.render("telegram", actions, ["a1"])

    assert String.contains?(text, "-> hello world")
    refute String.contains?(text, "%AgentCore.Types.AgentToolResult")
    refute String.contains?(text, "%Ai.Types.TextContent")
  end
end

