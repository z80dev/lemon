defmodule CodingAgent.Tools.SearchMemoryTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.SearchMemory

  test "uses agent context for agent scope without requiring scope_key" do
    tool =
      SearchMemory.tool("/tmp/project",
        session_key: "session-1",
        agent_id: "agent-123",
        search_fn: fn query, opts ->
          send(self(), {:search, query, opts})
          [%{id: "doc-1"}]
        end,
        format_results_fn: fn _docs -> "agent-scope-hit" end
      )

    result = tool.execute.("call-1", %{"query" => "fix bug", "scope" => "agent"}, nil, nil)

    assert_receive {:search, "fix bug", [scope: :agent, scope_key: "agent-123", limit: 5]}

    assert %AgentToolResult{
             content: [%TextContent{text: "agent-scope-hit"}],
             details: %{count: 1, query: "fix bug", scope: :agent}
           } = result
  end

  test "uses workspace context for workspace scope without requiring scope_key" do
    tool =
      SearchMemory.tool("/tmp/project",
        workspace_dir: "/tmp/workspace",
        search_fn: fn query, opts ->
          send(self(), {:search, query, opts})
          [%{id: "doc-1"}, %{id: "doc-2"}]
        end,
        format_results_fn: fn _docs -> "workspace-scope-hit" end
      )

    result =
      tool.execute.("call-2", %{"query" => "deploy steps", "scope" => "workspace"}, nil, nil)

    assert_receive {:search, "deploy steps",
                    [scope: :workspace, scope_key: "/tmp/workspace", limit: 5]}

    assert %AgentToolResult{
             content: [%TextContent{text: "workspace-scope-hit"}],
             details: %{count: 2, query: "deploy steps", scope: :workspace}
           } = result
  end

  test "returns an explicit error instead of broadening agent scope when context is missing" do
    tool =
      SearchMemory.tool("/tmp/project",
        search_fn: fn query, opts ->
          send(self(), {:search, query, opts})
          []
        end,
        format_results_fn: fn _docs -> "should-not-run" end
      )

    result = tool.execute.("call-3", %{"query" => "history", "scope" => "agent"}, nil, nil)

    refute_received {:search, _, _}

    assert %AgentToolResult{
             content: [%TextContent{text: text}],
             details: %{query: "history", scope: :agent}
           } = result

    assert text == "search_memory scope 'agent' requires a current agent context"
  end

  test "uses session context for the default scope" do
    tool =
      SearchMemory.tool("/tmp/project",
        session_key: "session-abc",
        search_fn: fn query, opts ->
          send(self(), {:search, query, opts})
          []
        end,
        format_results_fn: fn _docs -> "no hits" end
      )

    result = tool.execute.("call-4", %{"query" => "notes"}, nil, nil)

    assert_receive {:search, "notes", [scope: :session, scope_key: "session-abc", limit: 5]}

    assert %AgentToolResult{
             content: [%TextContent{text: "no hits"}],
             details: %{count: 0, query: "notes", scope: :session}
           } = result
  end
end
