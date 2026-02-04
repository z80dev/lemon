defmodule CodingAgent.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.{ToolExecutor, ToolPolicy}

  describe "wrap_with_approval/3" do
    test "returns tool unchanged when not in require_approval list" do
      tool = %AgentTool{
        name: "read",
        description: "Read a file",
        execute: fn _, _, _, _ -> %AgentToolResult{content: []} end
      }

      policy = ToolPolicy.from_profile(:full_access)
      context = %{run_id: "test", session_key: "agent:test:main"}

      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)

      # Should be the same tool (unchanged)
      assert wrapped.name == tool.name
      assert wrapped.execute == tool.execute
    end

    test "wraps tool when in require_approval list" do
      tool = %AgentTool{
        name: "write",
        description: "Write a file",
        execute: fn _, _, _, _ -> %AgentToolResult{content: []} end
      }

      policy = ToolPolicy.from_profile(:subagent_restricted)
      context = %{run_id: "test", session_key: "agent:test:main"}

      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)

      # The execute function should be different (wrapped)
      assert wrapped.name == tool.name
      assert wrapped.execute != tool.execute
    end
  end

  describe "wrap_all_with_approval/3" do
    test "wraps only tools that require approval" do
      read_tool = %AgentTool{
        name: "read",
        description: "Read a file",
        execute: fn _, _, _, _ -> :read_result end
      }

      write_tool = %AgentTool{
        name: "write",
        description: "Write a file",
        execute: fn _, _, _, _ -> :write_result end
      }

      edit_tool = %AgentTool{
        name: "edit",
        description: "Edit a file",
        execute: fn _, _, _, _ -> :edit_result end
      }

      tools = [read_tool, write_tool, edit_tool]
      policy = ToolPolicy.from_profile(:subagent_restricted)
      context = %{run_id: "test", session_key: "agent:test:main"}

      wrapped = ToolExecutor.wrap_all_with_approval(tools, policy, context)

      # Read should be unchanged
      read_wrapped = Enum.find(wrapped, &(&1.name == "read"))
      assert read_wrapped.execute == read_tool.execute

      # Write and edit should be wrapped (different execute function)
      write_wrapped = Enum.find(wrapped, &(&1.name == "write"))
      assert write_wrapped.execute != write_tool.execute

      edit_wrapped = Enum.find(wrapped, &(&1.name == "edit"))
      assert edit_wrapped.execute != edit_tool.execute
    end
  end

  describe "execute_with_approval/4" do
    setup do
      # Ensure LemonGateway.Store is running for approval tests
      case Process.whereis(LemonGateway.Store) do
        nil ->
          {:ok, _} = LemonGateway.Store.start_link([])
        _pid ->
          :ok
      end

      :ok
    end

    test "executes function when pre-approved globally" do
      session_key = "agent:test-global:main"
      executed = :erlang.make_ref()
      action = %{command: "ls"}

      # Hash the action the same way ApprovalsBridge does
      action_hash =
        :crypto.hash(:sha256, :erlang.term_to_binary(action))
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      # Pre-approve the tool globally (using hashed action key)
      LemonCore.Store.put(:exec_approvals_policy, {"bash", action_hash}, %{
        approved: true,
        approved_at_ms: System.system_time(:millisecond)
      })

      context = %{
        run_id: "test-run",
        session_key: session_key,
        timeout_ms: 100
      }

      result =
        ToolExecutor.execute_with_approval(
          "bash",
          action,
          fn ->
            %AgentToolResult{
              content: [%TextContent{type: :text, text: "executed #{inspect(executed)}"}]
            }
          end,
          context
        )

      # The result should contain our expected text
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.contains?(text, inspect(executed))

      # Cleanup
      LemonCore.Store.delete(:exec_approvals_policy, {"bash", action_hash})
    end

    test "returns timeout result when approval times out" do
      context = %{
        run_id: "test-timeout",
        session_key: "agent:timeout:main",
        timeout_ms: 10
      }

      result =
        ToolExecutor.execute_with_approval(
          "dangerous_tool",
          %{action: "delete"},
          fn ->
            %AgentToolResult{content: [%TextContent{type: :text, text: "should not execute"}]}
          end,
          context
        )

      # Should get a timeout result
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.contains?(text, "timed out waiting for approval")
    end
  end

  describe "policy integration" do
    test "subagent_restricted policy requires approval for write and edit" do
      policy = ToolPolicy.from_profile(:subagent_restricted)

      assert ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "edit")
      refute ToolPolicy.requires_approval?(policy, "read")
      refute ToolPolicy.requires_approval?(policy, "bash")
    end

    test "full_access policy requires no approvals" do
      policy = ToolPolicy.from_profile(:full_access)

      refute ToolPolicy.requires_approval?(policy, "write")
      refute ToolPolicy.requires_approval?(policy, "edit")
      refute ToolPolicy.requires_approval?(policy, "bash")
    end

    test "custom policy can require approval for any tool" do
      policy = ToolPolicy.custom(require_approval: ["bash", "write", "delete"])

      assert ToolPolicy.requires_approval?(policy, "bash")
      assert ToolPolicy.requires_approval?(policy, "write")
      assert ToolPolicy.requires_approval?(policy, "delete")
      refute ToolPolicy.requires_approval?(policy, "read")
    end
  end
end
