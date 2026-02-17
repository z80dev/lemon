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

  test "telegram shows only the 5 most recent tool calls and omits older ones" do
    actions =
      for i <- 1..7, into: %{} do
        id = "a#{i}"

        {id,
         %{
           title: "Tool #{i}",
           phase: :completed,
           ok: true,
           detail: %{result_preview: "ok"}
         }}
      end

    order = Enum.map(1..7, &"a#{&1}")

    text = ToolStatusRenderer.render("telegram", actions, order)

    assert String.contains?(text, "2 tools omitted")

    # Keep the most recent 5 only (a3..a7)
    refute String.contains?(text, "Tool 1")
    refute String.contains?(text, "Tool 2")
    assert String.contains?(text, "Tool 3")
    assert String.contains?(text, "Tool 7")
  end

  test "non-telegram channels keep full tool call list" do
    actions = %{
      "a1" => %{title: "Tool 1", phase: :completed, ok: true, detail: %{result_preview: "ok"}},
      "a2" => %{title: "Tool 2", phase: :completed, ok: true, detail: %{result_preview: "ok"}},
      "a3" => %{title: "Tool 3", phase: :completed, ok: true, detail: %{result_preview: "ok"}},
      "a4" => %{title: "Tool 4", phase: :completed, ok: true, detail: %{result_preview: "ok"}},
      "a5" => %{title: "Tool 5", phase: :completed, ok: true, detail: %{result_preview: "ok"}},
      "a6" => %{title: "Tool 6", phase: :completed, ok: true, detail: %{result_preview: "ok"}}
    }

    order = Enum.map(1..6, &"a#{&1}")
    text = ToolStatusRenderer.render("discord", actions, order)

    refute String.contains?(text, "omitted")
    assert String.contains?(text, "Tool 1")
    assert String.contains?(text, "Tool 6")
  end

  test "telegram command actions show bash command details" do
    actions = %{
      "a1" => %{
        title: "Bash",
        kind: :command,
        phase: :started,
        detail: %{name: "Bash", args: %{"command" => "npm test -- --watch=false"}}
      }
    }

    text = ToolStatusRenderer.render("telegram", actions, ["a1"])

    assert String.contains?(text, "cmd: \"npm test -- --watch=false\"")
  end

  test "telegram completed command actions show status metadata" do
    actions = %{
      "a1" => %{
        title: "Bash",
        kind: :command,
        phase: :completed,
        ok: false,
        detail: %{status: "failed", exit_code: 127, command: "nonexistent_command"}
      }
    }

    text = ToolStatusRenderer.render("telegram", actions, ["a1"])

    assert String.contains?(text, "(status=failed exit=127)")
    assert String.contains?(text, "cmd: \"nonexistent_command\"")
  end

  test "does not duplicate command text when already in title" do
    actions = %{
      "a1" => %{
        title: "$ ls -la",
        kind: :command,
        phase: :started,
        detail: %{name: "Bash", command: "ls -la"}
      }
    }

    text = ToolStatusRenderer.render("telegram", actions, ["a1"])

    refute String.contains?(text, "cmd:")
    assert String.contains?(text, "$ ls -la")
  end
end
