defmodule CodingAgent.ToolExecutor do
  @moduledoc """
  Tool execution wrapper that integrates approval gating.

  This module provides a way to wrap tool execution with approval checks
  based on the ToolPolicy. When a tool requires approval, execution is
  paused until approval is granted or denied.

  Approval failures are fail-closed. Exceptions, exits, throws, malformed
  replies, and unknown scopes never authorize execution. Raw approval-service
  failures are not included in tool results or logs. The failure boundary
  covers only the approval request, not the approved tool's execution.

  ## Usage

      # Wrap a tool with approval enforcement
      wrapped_tool = ToolExecutor.wrap_with_approval(tool, policy, context)

      # Or wrap all tools in a list
      wrapped_tools = ToolExecutor.wrap_all_with_approval(tools, policy, context)

  ## Context

  The context map should include:
  - `:run_id` - The current run ID
  - `:session_id` - The native CodingAgent session ID
  - `:session_key` - The session key for routing
  - `:timeout_ms` - Approval timeout in milliseconds (optional; default: no timeout)
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias CodingAgent.ToolPolicy

  require Logger

  # Tool calls should not enforce approval timeouts by default.
  @default_timeout_ms :infinity

  # ExecApprovals returns stored-policy scopes or the explicit resolution decision.
  @approval_scopes [
    :once,
    :session,
    :agent,
    :node,
    :global,
    :approve_once,
    :approve_session,
    :approve_agent,
    :approve_global
  ]

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

  This function blocks until approval is granted, denied, times out, or fails.
  Only an explicit approval at a supported scope executes the callback.

  Returns:
  - The tool result on success
  - An error result if approval is denied, times out, or is unavailable
  """
  @spec execute_with_approval(
          tool_name :: String.t(),
          args :: map(),
          execute_fn :: function(),
          context :: map()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute_with_approval(tool_name, args, execute_fn, context) do
    run_id = context[:run_id]
    session_id = context[:session_id]
    session_key = context[:session_key]
    timeout_ms = context[:timeout_ms] || @default_timeout_ms
    approval_request_fun = context[:approval_request_fun] || (&LemonCore.ExecApprovals.request/1)

    case request_approval(
           run_id,
           session_id,
           session_key,
           tool_name,
           args,
           timeout_ms,
           approval_request_fun
         ) do
      {:ok, :approved, scope} when scope in @approval_scopes ->
        Logger.debug("Tool #{tool_name} approved at scope: #{scope}")
        execute_fn.()

      {:ok, :denied} ->
        Logger.info("Tool #{tool_name} denied by approval")
        denied_result(tool_name)

      {:error, :timeout} ->
        Logger.warning("Tool #{tool_name} approval timed out")
        timeout_result(tool_name, timeout_ms)

      {:error, reason} ->
        safe_reason = safe_approval_error(reason)
        Logger.warning("Tool #{tool_name} approval failed: #{safe_reason}")
        approval_error_result(tool_name, safe_reason)

      _other ->
        Logger.warning("Tool #{tool_name} approval returned an invalid response")
        approval_error_result(tool_name, :invalid_approval_response)
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

  defp request_approval(run_id, session_id, session_key, tool_name, args, timeout_ms, request_fun) do
    request_fun.(%{
      run_id: run_id,
      session_id: session_id,
      session_key: session_key,
      tool: tool_name,
      action: args,
      rationale: "Tool execution: #{tool_name}",
      expires_in_ms: timeout_ms
    })
  catch
    _kind, _reason ->
      # Authorization is never inferred from a failed request. Catch error,
      # exit, and throw here without exposing arbitrary service error terms.
      {:error, :approval_unavailable}
  end

  defp safe_approval_error(reason) when reason in [:approval_unavailable, :service_unavailable],
    do: reason

  defp safe_approval_error(_reason), do: :approval_request_failed

  defp denied_result(tool_name) do
    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text:
            "Tool '#{tool_name}' execution was denied. The operation requires approval that was not granted."
        }
      ],
      details: %{
        denied: true,
        reason: :approval_denied
      }
    }
  end

  defp timeout_result(tool_name, timeout_ms) do
    timeout_label =
      if is_integer(timeout_ms), do: " (#{div(timeout_ms, 1000)}s)", else: ""

    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text:
            "Tool '#{tool_name}' execution timed out waiting for approval#{timeout_label}. " <>
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

  defp approval_error_result(tool_name, reason) do
    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text:
            "Tool '#{tool_name}' could not run because approval failed: #{reason}. " <>
              "Please retry or approve manually."
        }
      ],
      details: %{
        approval_error: reason,
        reason: :approval_error
      }
    }
  end
end
