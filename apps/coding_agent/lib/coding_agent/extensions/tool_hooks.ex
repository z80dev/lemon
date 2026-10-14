defmodule CodingAgent.Extensions.ToolHooks do
  @moduledoc """
  Interception wrapper that runs extension `:on_tool_call` and
  `:on_tool_result` hooks around session tool execution.

  `CodingAgent.ExtensionLifecycle` applies this wrapper to every session tool
  (built-in, extension, MCP, WASM, extra and custom tools, including those
  hidden behind the `tool_invoke` disclosure bridge) after approval wrapping.
  The resulting order, outermost first, is: secret placeholder restore →
  extension tool hooks → approval → tool. Tools are returned unchanged when no
  extension registers either hook.

  ## `:on_tool_call`

  Each handler receives
  `%{tool_call_id: id, tool_name: name, args: args, cwd: cwd, session_id: id}`
  and may return:

    * `{:block, reason}` — the tool does not run; the model receives an error
      tool result naming the (bounded) reason. The first block short-circuits
      the remaining handlers.
    * `{:replace_args, map}` — the tool runs with `map` instead of the model's
      arguments. When several handlers replace arguments the last one wins;
      handlers all see the original arguments, not each other's revisions.
    * anything else — no effect.

  A handler that raises, throws or exits fails closed: the call is blocked with
  a generic reason, and the failure is logged without the arguments.

  ## `:on_tool_result`

  Each handler receives
  `%{tool_call_id, tool_name, args, result, is_error, cwd, session_id}` where
  `args` are the arguments the tool actually ran with and `result` is an
  `AgentToolResult`. On success a handler may return
  `{:replace, %AgentToolResult{}}` or `{:replace, %{content: ..., details: ...}}`
  to override the result content and/or details (last replacement wins; the
  original trust level and error status are kept). Anything else is a no-op and
  a failing handler keeps the original result.

  When the tool returns an error result, `{:error, reason}`, or raises, the
  handlers observe it with `is_error: true` and the original error behavior is
  preserved (replacements are ignored, raises are re-raised).
  """

  require Logger

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @interception_events [:on_tool_call, :on_tool_result]
  @max_reason_length 500
  @failed_reason "an extension hook failed while checking this tool call"

  @typedoc "Session facts included in every tool hook event."
  @type context :: %{
          optional(:cwd) => String.t() | nil,
          optional(:session_id) => String.t() | nil
        }

  @doc """
  Returns true when `hooks` contains at least one tool interception handler.
  """
  @spec active?(keyword([function()])) :: boolean()
  def active?(hooks) when is_list(hooks) do
    Enum.any?(@interception_events, fn event -> Keyword.get(hooks, event, []) != [] end)
  end

  def active?(_hooks), do: false

  @doc """
  Wraps each tool with the interception hooks. Returns `tools` unchanged when
  no interception hook is registered.
  """
  @spec wrap_tools([AgentTool.t()], keyword([function()]), context()) :: [AgentTool.t()]
  def wrap_tools(tools, hooks, context) do
    if active?(hooks) do
      Enum.map(tools, &wrap_tool(&1, hooks, context))
    else
      tools
    end
  end

  @doc """
  Same as `wrap_tools/3` for `CodingAgent.ToolRegistry` `{name, tool, source}`
  tuples.
  """
  @spec wrap_tuples([{String.t(), AgentTool.t(), term()}], keyword([function()]), context()) ::
          [{String.t(), AgentTool.t(), term()}]
  def wrap_tuples(tuples, hooks, context) do
    if active?(hooks) do
      Enum.map(tuples, fn {name, tool, source} ->
        {name, wrap_tool(tool, hooks, context), source}
      end)
    else
      tuples
    end
  end

  @doc """
  Wraps a single tool with the interception hooks in `hooks`.
  """
  @spec wrap_tool(AgentTool.t(), keyword([function()]), context()) :: AgentTool.t()
  def wrap_tool(%AgentTool{} = tool, hooks, context) do
    call_hooks = Keyword.get(hooks, :on_tool_call, [])
    result_hooks = Keyword.get(hooks, :on_tool_result, [])
    original_execute = tool.execute

    base_event = %{
      tool_name: tool.name,
      cwd: Map.get(context, :cwd),
      session_id: Map.get(context, :session_id)
    }

    wrapped_execute = fn tool_call_id, params, signal, on_update ->
      event = Map.merge(base_event, %{tool_call_id: tool_call_id, args: params})

      case run_call_hooks(call_hooks, event) do
        {:block, reason} ->
          blocked_result(tool.name, reason)

        {:ok, args} ->
          event = %{event | args: args}
          execute(args, tool_call_id, signal, on_update, original_execute, result_hooks, event)
      end
    end

    %{tool | execute: wrapped_execute}
  end

  # ── on_tool_call ──────────────────────────────────────────────────────────

  defp run_call_hooks([], event), do: {:ok, event.args}

  defp run_call_hooks(hooks, event) do
    Enum.reduce_while(hooks, {:ok, event.args}, fn hook, {:ok, args} ->
      case invoke_call_hook(hook, event) do
        {:block, reason} -> {:halt, {:block, reason}}
        {:replace_args, new_args} -> {:cont, {:ok, new_args}}
        :pass -> {:cont, {:ok, args}}
      end
    end)
  end

  defp invoke_call_hook(hook, event) do
    case hook.(event) do
      {:block, reason} -> {:block, bound_reason(reason)}
      {:replace_args, args} when is_map(args) -> {:replace_args, args}
      _other -> :pass
    end
  rescue
    exception ->
      log_failure(:on_tool_call, event.tool_name, :error, exception)
      {:block, @failed_reason}
  catch
    kind, reason ->
      log_failure(:on_tool_call, event.tool_name, kind, reason)
      {:block, @failed_reason}
  end

  defp bound_reason(reason) when is_binary(reason) do
    if String.valid?(reason) do
      reason
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
      |> String.trim()
      |> truncate()
      |> case do
        "" -> "no reason given"
        bounded -> bounded
      end
    else
      "no reason given"
    end
  end

  defp bound_reason(_reason), do: "no reason given"

  defp truncate(text) do
    if String.length(text) > @max_reason_length do
      String.slice(text, 0, @max_reason_length) <> "…"
    else
      text
    end
  end

  defp blocked_result(tool_name, reason) do
    %AgentToolResult{
      content: [
        %TextContent{
          type: :text,
          text: "Tool '#{tool_name}' was blocked by an extension hook: #{reason}"
        }
      ],
      details: %{blocked: true, reason: :hook_blocked, hook_reason: reason},
      is_error: true
    }
  end

  # ── execution + on_tool_result ────────────────────────────────────────────

  defp execute(args, tool_call_id, signal, on_update, original_execute, [], _event) do
    original_execute.(tool_call_id, args, signal, on_update)
  end

  defp execute(args, tool_call_id, signal, on_update, original_execute, result_hooks, event) do
    outcome =
      try do
        original_execute.(tool_call_id, args, signal, on_update)
      rescue
        exception ->
          observe_error(result_hooks, event, error_result(Exception.message(exception)))
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          observe_error(result_hooks, event, error_result("#{kind}: #{inspect(reason)}"))
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case outcome do
      %AgentToolResult{is_error: false} = result ->
        apply_result_hooks(result_hooks, event, result)

      {:ok, %AgentToolResult{is_error: false} = result} ->
        {:ok, apply_result_hooks(result_hooks, event, result)}

      %AgentToolResult{} = result ->
        observe_error(result_hooks, event, result)
        outcome

      {:ok, %AgentToolResult{} = result} ->
        observe_error(result_hooks, event, result)
        outcome

      {:error, reason} ->
        observe_error(result_hooks, event, error_result(error_text(reason)))
        outcome

      other ->
        observe_error(
          result_hooks,
          event,
          error_result("Unexpected tool result: #{inspect(other)}")
        )

        outcome
    end
  end

  defp apply_result_hooks(hooks, event, result) do
    event = Map.merge(event, %{result: result, is_error: false})

    hooks
    |> Enum.reduce(nil, fn hook, override ->
      case invoke_result_hook(hook, event) do
        {:replace, replacement} -> replacement
        :pass -> override
      end
    end)
    |> apply_override(result)
  end

  defp observe_error(hooks, event, result) do
    event = Map.merge(event, %{result: result, is_error: true})
    Enum.each(hooks, &invoke_result_hook(&1, event))
  end

  defp invoke_result_hook(hook, event) do
    case hook.(event) do
      {:replace, %AgentToolResult{content: content, details: details}} when is_list(content) ->
        {:replace, %{content: content, details: details}}

      {:replace, %{} = replacement} when not is_struct(replacement) ->
        valid_replacement(replacement, event.tool_name)

      _other ->
        :pass
    end
  rescue
    exception ->
      log_failure(:on_tool_result, event.tool_name, :error, exception)
      :pass
  catch
    kind, reason ->
      log_failure(:on_tool_result, event.tool_name, kind, reason)
      :pass
  end

  defp valid_replacement(replacement, tool_name) do
    case Map.fetch(replacement, :content) do
      {:ok, content} when not is_list(content) ->
        Logger.warning(
          "Extension on_tool_result hook for #{tool_name} returned non-list content; ignored"
        )

        :pass

      _ ->
        {:replace, Map.take(replacement, [:content, :details])}
    end
  end

  defp apply_override(nil, result), do: result

  defp apply_override(override, result) do
    %{
      result
      | content: Map.get(override, :content, result.content),
        details: Map.get(override, :details, result.details)
    }
  end

  defp error_result(text) do
    %AgentToolResult{content: [%TextContent{type: :text, text: text}], is_error: true}
  end

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

  # Tool arguments and handler exception messages can echo secrets; log only
  # the failure class.
  defp log_failure(event, tool_name, :error, %{__exception__: true} = exception) do
    Logger.warning(
      "Extension #{event} hook failed for tool #{tool_name}: #{inspect(exception.__struct__)}"
    )
  end

  defp log_failure(event, tool_name, kind, _reason) do
    Logger.warning("Extension #{event} hook failed for tool #{tool_name}: #{kind}")
  end
end
