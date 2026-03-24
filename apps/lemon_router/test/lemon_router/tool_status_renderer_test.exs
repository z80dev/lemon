defmodule LemonRouter.ToolStatusRendererTest do
  use ExUnit.Case, async: true

  alias LemonRouter.ToolStatusRenderer

  test "renders error result preview on failed actions" do
    actions = %{
      "a1" => %{
        title: "Test tool",
        phase: :completed,
        ok: false,
        detail: %{result_preview: "something went wrong"}
      }
    }

    text = ToolStatusRenderer.render("telegram", actions, ["a1"])

    assert String.contains?(text, "\u2717 Test tool -> something went wrong")
  end

  test "does not render result preview on successful actions" do
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

    assert String.contains?(text, "\u2713 Test tool")
    refute String.contains?(text, "->")
    refute String.contains?(text, "%AgentCore.Types.AgentToolResult")
  end

  test "telegram truncates tool list when more than 5 tools, showing last 4 + omitted line" do
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

    # 7 tools total, keep last 4 (Tool 4-7), omit first 3
    assert String.contains?(text, "(3 tools omitted)")
    assert String.contains?(text, "Tool 4")
    assert String.contains?(text, "Tool 7")
    # Tool 1-3 should NOT appear
    refute String.contains?(text, "Tool 1")
    refute String.contains?(text, "Tool 2")
    refute String.contains?(text, "Tool 3")
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

  test "router renderer does not inject channel-specific command detail text" do
    actions = %{
      "a1" => %{
        title: "Bash",
        kind: :command,
        phase: :started,
        detail: %{name: "Bash", args: %{"command" => "npm test -- --watch=false"}}
      }
    }

    text = ToolStatusRenderer.render("telegram", actions, ["a1"])

    assert String.contains?(text, "▸ Bash")
    refute String.contains?(text, "cmd:")
  end

  test "router renderer does not inject channel-specific command status metadata" do
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

    assert String.contains?(text, "✗ Bash")
    refute String.contains?(text, "status=")
    refute String.contains?(text, "cmd:")
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

  test "uses unicode symbols for action phases" do
    actions = %{
      "a1" => %{title: "read foo", phase: :started, ok: nil},
      "a2" => %{title: "grep bar", phase: :completed, ok: true},
      "a3" => %{
        title: "npm test",
        phase: :completed,
        ok: false,
        detail: %{result_preview: "Command failed"}
      }
    }

    text = ToolStatusRenderer.render("telegram", actions, ["a1", "a2", "a3"])

    assert String.contains?(text, "\u25b8 read foo")
    assert String.contains?(text, "\u2713 grep bar")
    assert String.contains?(text, "\u2717 npm test -> Command failed")
  end

  test "indents child actions when parent_tool_use_id is present" do
    actions = %{
      "task_1" => %{title: "Task: investigate", phase: :started, ok: nil, detail: %{}},
      "child_1" => %{
        title: "Read: foo.ex",
        phase: :completed,
        ok: true,
        detail: %{parent_tool_use_id: "task_1", result_preview: "ok"}
      },
      "grandchild_1" => %{
        title: "Grep: defmodule",
        phase: :completed,
        ok: true,
        detail: %{parent_tool_use_id: "child_1", result_preview: "1 match"}
      }
    }

    text = ToolStatusRenderer.render("telegram", actions, ["task_1", "child_1", "grandchild_1"])

    assert String.contains?(text, "▸ Task: investigate")
    assert String.contains?(text, "  ✓ Read: foo.ex")
    assert String.contains?(text, "    ✓ Grep: defmodule")
  end

  test "empty order renders just header" do
    text = ToolStatusRenderer.render("telegram", %{}, [])
    assert text == "working"
  end

  test "render/4 with opts builds rich header" do
    actions = %{
      "a1" => %{title: "read foo", phase: :started, ok: nil}
    }

    opts = %{elapsed_ms: 1500, engine: "claude", action_count: 3}
    text = ToolStatusRenderer.render("telegram", actions, ["a1"], opts)

    assert String.starts_with?(text, "working \u00b7 claude \u00b7 1s \u00b7 step 3")
  end

  test "render/4 with nil elapsed_ms shows just working header" do
    actions = %{
      "a1" => %{title: "read foo", phase: :started, ok: nil}
    }

    opts = %{elapsed_ms: nil, engine: nil, action_count: 0}
    text = ToolStatusRenderer.render("telegram", actions, ["a1"], opts)

    [header | _] = String.split(text, "\n")
    assert header == "working"
  end

  test "render/4 formats minutes and seconds" do
    actions = %{
      "a1" => %{title: "read foo", phase: :started, ok: nil}
    }

    opts = %{elapsed_ms: 150_000, engine: "claude", action_count: 5}
    text = ToolStatusRenderer.render("telegram", actions, ["a1"], opts)

    assert String.contains?(text, "2m 30s")
  end

  test "telegram with exactly 5 tools shows all, no omission" do
    actions =
      for i <- 1..5, into: %{} do
        {"a#{i}", %{title: "Tool #{i}", phase: :completed, ok: true, detail: %{}}}
      end

    order = Enum.map(1..5, &"a#{&1}")
    text = ToolStatusRenderer.render("telegram", actions, order)

    refute String.contains?(text, "omitted")
    for i <- 1..5, do: assert(String.contains?(text, "Tool #{i}"))
  end

  test "telegram with 6 tools omits first 2, keeps last 4" do
    actions =
      for i <- 1..6, into: %{} do
        {"a#{i}", %{title: "Tool #{i}", phase: :completed, ok: true, detail: %{}}}
      end

    order = Enum.map(1..6, &"a#{&1}")
    text = ToolStatusRenderer.render("telegram", actions, order)

    assert String.contains?(text, "(2 tools omitted)")
    assert String.contains?(text, "Tool 3")
    assert String.contains?(text, "Tool 6")
    refute String.contains?(text, "Tool 1")
    refute String.contains?(text, "Tool 2")
  end

  test "whatsapp also truncates like telegram" do
    actions =
      for i <- 1..6, into: %{} do
        {"a#{i}", %{title: "Tool #{i}", phase: :completed, ok: true, detail: %{}}}
      end

    order = Enum.map(1..6, &"a#{&1}")
    text = ToolStatusRenderer.render("whatsapp:12345", actions, order)

    assert String.contains?(text, "(2 tools omitted)")
    refute String.contains?(text, "Tool 1")
    assert String.contains?(text, "Tool 6")
  end

  test "nil channel_id does not truncate" do
    actions =
      for i <- 1..7, into: %{} do
        {"a#{i}", %{title: "Tool #{i}", phase: :completed, ok: true, detail: %{}}}
      end

    order = Enum.map(1..7, &"a#{&1}")
    text = ToolStatusRenderer.render(nil, actions, order)

    refute String.contains?(text, "omitted")
    for i <- 1..7, do: assert(String.contains?(text, "Tool #{i}"))
  end
end
