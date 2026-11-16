defmodule CodingAgent.McpApprovalTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ToolRegistry
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  test "configured per-tool approval cannot be bypassed by a permissive session", %{tmp_dir: cwd} do
    owner = self()

    tool =
      resolved_tool(cwd, :always, %{approvals: %{"mcp_test" => :never}}, fn request ->
        send(owner, {:approval, request.tool})
        {:ok, :denied}
      end)

    assert %AgentToolResult{is_error: true} = tool.execute.("denied", %{}, nil, nil)
    assert_receive {:approval, "mcp_test"}
    refute_receive :mcp_executed
  end

  test "per-tool never cannot bypass a stricter session policy", %{tmp_dir: cwd} do
    owner = self()

    tool =
      resolved_tool(cwd, :never, %{approvals: %{"mcp_test" => :always}}, fn _ ->
        send(owner, :approval)
        {:ok, :denied}
      end)

    assert %AgentToolResult{is_error: true} = tool.execute.("denied", %{}, nil, nil)
    assert_receive :approval
    refute_receive :mcp_executed
  end

  test "approval allows one invocation without duplicate approval wrapping", %{tmp_dir: cwd} do
    owner = self()

    tool =
      resolved_tool(
        cwd,
        :always,
        %{approvals: %{"mcp_test" => :always}},
        fn _ ->
          send(owner, :approval)
          {:ok, :approved, :once}
        end,
        tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(cwd)
      )

    assert %AgentToolResult{content: [%TextContent{text: "remote result"}]} =
             tool.execute.("approved", %{}, nil, nil)

    assert_receive :approval
    assert_receive :mcp_executed
    refute_receive :approval
    refute_receive :mcp_executed
  end

  test "never invokes directly when neither policy requires approval", %{tmp_dir: cwd} do
    tool =
      resolved_tool(cwd, :never, nil, fn _ -> flunk("approval was not required") end,
        tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(cwd)
      )

    assert %AgentToolResult{} = tool.execute.("allowed", %{}, nil, nil)
    assert_receive :mcp_executed
  end

  test "deferred tool discovery preserves MCP approval gates", %{tmp_dir: cwd} do
    tool = resolved_tool(cwd, :always, nil, fn _ -> {:ok, :denied} end)

    %{tools: exposed} =
      CodingAgent.ToolDisclosure.apply(
        [{tool.name, tool, {:mcp, %{approval: :always}}}],
        [],
        %{enabled: true, budget_tokens: 1, catalog_tokens: 2000, max_results: 5}
      )

    invoke = Enum.find(exposed, &(&1.name == "tool_invoke"))
    assert invoke

    assert %AgentToolResult{is_error: true} =
             invoke.execute.("deferred", %{"name" => tool.name, "args" => %{}}, nil, nil)

    refute_receive :mcp_executed
  end

  defp resolved_tool(cwd, mode, policy, request, opts \\ []) do
    owner = self()

    tool = %AgentTool{
      name: "mcp_test",
      label: "MCP test",
      description: "A controlled remote operation",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ ->
        send(owner, :mcp_executed)
        %AgentToolResult{content: [%TextContent{text: "remote result"}], trust: :untrusted}
      end
    }

    [resolved] =
      ToolRegistry.get_tools(
        cwd,
        [
          include_extensions: false,
          enabled_only: [tool.name],
          mcp_tools: [{tool.name, tool, {:mcp, %{approval: mode}}}],
          tool_policy: policy,
          approval_context: %{session_id: "policy-test", approval_request_fun: request}
        ] ++ opts
      )

    resolved
  end
end
