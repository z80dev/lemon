defmodule CodingAgent.ToolExecutor do
  @moduledoc """
  Tool execution wrapper that integrates approval gating.

  This module provides a way to wrap tool execution with approval checks
  based on the ToolPolicy. When a tool requires approval, execution is
  paused until approval is granted or denied.

  ## Usage

      # Wrap a tool with approval enforcement
      wrapped_tool = ToolExecutor.wrap_with_approval(tool, policy, context)

      # Or wrap all tools in a list
      wrapped_tools = ToolExecutor.wrap_all_with_approval(tools, policy, context)

  ## Context

  The context map should include:
  - `:run_id` - The current run ID
  - `:session_key` - The session key for routing
  - `:timeout_ms` - Approval timeout in milliseconds (default: 300000)
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.ToolPolicy

  require Logger

  @default_timeout_ms 300_000

  @doc """
  Wrap a single tool with approval checks.

  If the tool doesn't require approval according to the policy, it is
  returned unchanged.
  """
  @spec wrap_with_approval(AgentTool.t(), ToolPolicy.policy(), map()) :: AgentTool.t()
  def wrap_with_approval(%AgentTool{} = tool, policy, context) do
    if ToolPolicy.requires_approval?(policy, tool.name) do
      wrap_tool(tool, context)
    else
      tool
    end
  end

  @doc """
  Wrap all tools in a list with approval checks based on the policy.
  """
  @spec wrap_all_with_approval([AgentTool.t()], ToolPolicy.policy(), map()) :: [AgentTool.t()]
  def wrap_all_with_approval(tools, policy, context) do
    Enum.map(tools, fn tool ->
      wrap_with_approval(tool, policy, context)
    end)
  end

  @doc """
  Execute a tool with approval check.

  This function checks if approval is required and blocks until
  approval is granted, denied, or times out.

  Returns:
  - The tool result on success
  - An error result if approval is denied or times out
  """
  @spec execute_with_approval(
          tool_name :: String.t(),
          args :: map(),
          execute_fn :: function(),
          context :: map()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute_with_approval(tool_name, args, execute_fn, context) do
    run_id = context[:run_id]
    session_key = context[:session_key]
    timeout_ms = context[:timeout_ms] || @default_timeout_ms

    case request_approval(run_id, session_key, tool_name, args, timeout_ms) do
      {:ok, :approved, scope} ->
        Logger.debug("Tool #{tool_name} approved at scope: #{scope}")
        execute_fn.()

      {:ok, :denied} ->
        Logger.info("Tool #{tool_name} denied by approval")
        denied_result(tool_name)

      {:error, :timeout} ->
        Logger.warning("Tool #{tool_name} approval timed out")
        timeout_result(tool_name, timeout_ms)
    end
  end

  # Private helpers

  defp wrap_tool(%AgentTool{} = tool, context) do
    original_execute = tool.execute

    wrapped_execute = fn tool_call_id, params, signal, on_update ->
      execute_with_approval(
        tool.name,
        params,
        fn -> original_execute.(tool_call_id, params, signal, on_update) end,
        context
      )
    end

    %{tool | execute: wrapped_execute}
  end

  defp request_approval(run_id, session_key, tool_name, args, timeout_ms) do
    # Check if LemonRouter.ApprovalsBridge is available
    case Code.ensure_loaded(LemonRouter.ApprovalsBridge) do
      {:module, _} ->
        LemonRouter.ApprovalsBridge.request(%{
          run_id: run_id,
          session_key: session_key,
          tool: tool_name,
          action: args,
          rationale: "Tool execution: #{tool_name}",
          expires_in_ms: timeout_ms
        })

      _ ->
        # If ApprovalsBridge is not available, auto-approve
        Logger.debug("ApprovalsBridge not available, auto-approving #{tool_name}")
        {:ok, :approved, :auto}
    end
  end

  defp denied_result(tool_name) do
    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text: "Tool '#{tool_name}' execution was denied. The operation requires approval that was not granted."
        }
      ],
      details: %{
        denied: true,
        reason: :approval_denied
      }
    }
  end

  defp timeout_result(tool_name, timeout_ms) do
    timeout_seconds = div(timeout_ms, 1000)

    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text:
            "Tool '#{tool_name}' execution timed out waiting for approval (#{timeout_seconds}s). " <>
              "Please request approval and try again."
        }
      ],
      details: %{
        timeout: true,
        timeout_ms: timeout_ms,
        reason: :approval_timeout
      }
    }
  end
end
