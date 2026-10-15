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

  Denials, approval timeouts, and approval failures return an
  `AgentToolResult` with `is_error: true`, so the model sees an error tool
  result rather than a successful one.

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
  - `:agent_id` - The executing agent identity
  - `:invocation_context_key` - Trusted private grant namespace (optional)
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

  Argument-sensitive tools resolve the gate at execution time, including after
  an outer on_tool_call hook has rewritten arguments.
  """
  @spec wrap_with_approval(AgentTool.t(), ToolPolicy.policy(), map()) :: AgentTool.t()
  def wrap_with_approval(%AgentTool{} = tool, policy, context) do
    if tool.name == "lsp" or
         ToolPolicy.requires_approval?(policy, tool.name, %{}, context[:approval_tier]) do
      wrap_tool(tool, policy, context)
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
           context[:agent_id],
           context[:invocation_context_key],
           tool_name,
           args,
           timeout_ms,
           context[:tool_call_id],
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

  defp wrap_tool(%AgentTool{} = tool, policy, context) do
    original_execute = tool.execute

    wrapped_execute = fn tool_call_id, params, signal, on_update ->
      if ToolPolicy.requires_approval?(policy, tool.name, params, context[:approval_tier]) do
        execute_with_approval(
          tool.name,
          params,
          fn -> original_execute.(tool_call_id, params, signal, on_update) end,
          Map.put(context, :tool_call_id, tool_call_id)
        )
      else
        original_execute.(tool_call_id, params, signal, on_update)
      end
    end

    %{tool | execute: wrapped_execute}
  end

  defp request_approval(
         run_id,
         session_id,
         session_key,
         agent_id,
         invocation_context_key,
         tool_name,
         args,
         timeout_ms,
         tool_call_id,
         request_fun
       ) do
    request_fun.(%{
      run_id: run_id,
      session_id: session_id,
      session_key: session_key,
      agent_id: agent_id,
      invocation_context_key: invocation_context_key,
      tool_call_id: tool_call_id,
      tool: tool_name,
      action: project_action(tool_name, args),
      rationale: LemonAgent.ToolIntent.current() || "Tool execution: #{tool_name}",
      expires_in_ms: timeout_ms
    })
  catch
    _kind, _reason ->
      # Authorization is never inferred from a failed request. Catch error,
      # exit, and throw here without exposing arbitrary service error terms.
      {:error, :approval_unavailable}
  end

  # These arguments are approval/event projections, never execution input.
  # Env values may be secrets even under innocuous variable names.
  @doc false
  def project_action("bash", args)
      when is_map(args) and (is_map_key(args, "env") or is_map_key(args, :env)) do
    env =
      case Map.fetch(args, "env") do
        {:ok, env} -> env
        :error -> Map.get(args, :env)
      end

    keys =
      case env do
        env when is_map(env) -> env |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()
        _ -> []
      end

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(env))
      |> Base.encode16(case: :lower)

    args |> Map.drop(["env", :env]) |> Map.put("env_keys", keys) |> Map.put("env_digest", digest)
  end

  def project_action("tool_invoke", %{"name" => name, "args" => args} = params) do
    name = if is_binary(name), do: name |> String.trim() |> String.downcase(), else: name
    Map.put(params, "args", project_action(name, args))
  end

  def project_action(tool_name, args) when tool_name in ["remember", "skill_manage"] do
    LemonSkills.WriteApproval.project_action(args)
  end

  def project_action(_tool_name, args), do: args

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
      },
      is_error: true
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
      },
      is_error: true
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
      },
      is_error: true
    }
  end
end
