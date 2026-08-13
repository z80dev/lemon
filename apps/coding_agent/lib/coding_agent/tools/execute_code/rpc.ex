defmodule CodingAgent.Tools.ExecuteCode.Rpc do
  @moduledoc """
  The file-RPC pump that serves tool calls made by a running `execute_code`
  script.

  While the script task runs, `serve/2` polls the per-invocation rpc directory
  for `req-<id>.json` files, runs the requested tool through the same policy and
  approval machinery a direct tool call goes through, and writes
  `res-<id>.json` back atomically (`.tmp` + rename), so the script never reads a
  half-written response.

  Everything here happens outside the model transcript: the request and response
  payloads live only on disk, and the tool result the model eventually sees is
  the script's stdout.

  `serve/2` must run in the process that started the task — `Task.yield/2`
  requires task ownership, and the yield doubles as the poll sleep.
  """

  require Logger

  alias CodingAgent.ToolExecutor
  alias CodingAgent.ToolPolicy
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @type ctx :: %{
          tools: %{String.t() => LemonAgent.Types.AgentTool.t()},
          tool_policy: map() | nil,
          approval_context: map() | nil,
          max_calls: pos_integer(),
          max_result_bytes: pos_integer(),
          signal: reference() | nil,
          rpc_dir: String.t(),
          poll_interval_ms: pos_integer()
        }

  @type stats :: %{
          calls: non_neg_integer(),
          denied: non_neg_integer(),
          errors: non_neg_integer(),
          bytes: non_neg_integer(),
          tools_used: MapSet.t(String.t())
        }

  @doc """
  Returns zeroed pump statistics.
  """
  @spec initial_stats() :: stats()
  def initial_stats do
    %{calls: 0, denied: 0, errors: 0, bytes: 0, tools_used: MapSet.new()}
  end

  @doc """
  Serve RPC requests until the script task finishes.

  Returns `{:ok, task_result, stats}` when the task returned normally, or
  `{:exit, reason, stats}` when it died.
  """
  @spec serve(Task.t(), ctx()) :: {:ok | :exit, term(), stats()}
  def serve(%Task{} = task, ctx) do
    loop(task, ctx, initial_stats())
  end

  defp loop(task, ctx, stats) do
    case Task.yield(task, ctx.poll_interval_ms) do
      {:ok, result} ->
        # Deliberately no final drain: a script blocks until its response file
        # appears, so an unanswered request can only belong to a script that was
        # killed -- and running its tool now would be work nobody is waiting for
        # (and, after an abort, work that was explicitly cancelled).
        {:ok, result, stats}

      {:exit, reason} ->
        {:exit, reason, stats}

      nil ->
        loop(task, ctx, serve_pending(ctx, stats))
    end
  end

  defp serve_pending(ctx, stats) do
    ctx.rpc_dir
    |> pending_ids()
    |> Enum.reduce(stats, fn id, acc -> handle_request(id, ctx, acc) end)
  end

  defp pending_ids(rpc_dir) do
    rpc_dir
    |> Path.join("req-*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Integer.parse(Path.basename(path, ".json") |> String.replace_prefix("req-", "")) do
        {id, ""} -> [id]
        _ -> []
      end
    end)
    |> Enum.sort()
    |> Enum.reject(&File.exists?(response_path(rpc_dir, &1)))
  end

  defp handle_request(id, ctx, stats) do
    if stats.calls >= ctx.max_calls do
      respond_error(
        ctx,
        id,
        "rpc call limit exceeded (max #{ctx.max_calls} calls per script)"
      )

      %{stats | errors: stats.errors + 1}
    else
      stats = %{stats | calls: stats.calls + 1}
      dispatch(id, ctx, stats)
    end
  end

  defp dispatch(id, ctx, stats) do
    case read_request(ctx.rpc_dir, id) do
      {:ok, tool_name, params} ->
        run_tool(id, tool_name, params, ctx, stats)

      :error ->
        respond_error(ctx, id, "invalid rpc request")
        %{stats | errors: stats.errors + 1}
    end
  end

  defp read_request(rpc_dir, id) do
    with {:ok, body} <- File.read(request_path(rpc_dir, id)),
         {:ok, decoded} <- Jason.decode(body),
         %{"tool" => tool} when is_binary(tool) <- decoded,
         params when is_map(params) <- Map.get(decoded, "params") || %{} do
      {:ok, tool, params}
    else
      _ -> :error
    end
  end

  defp run_tool(id, tool_name, params, ctx, stats) do
    cond do
      not Map.has_key?(ctx.tools, tool_name) ->
        respond_error(ctx, id, "tool '#{tool_name}' is not available inside execute_code scripts")
        %{stats | errors: stats.errors + 1}

      denied_by_policy?(ctx.tool_policy, tool_name) ->
        reason =
          ToolPolicy.denial_reason(ctx.tool_policy, tool_name) ||
            "tool '#{tool_name}' denied by policy"

        respond_error(ctx, id, reason)
        %{stats | denied: stats.denied + 1}

      true ->
        execute(id, tool_name, params, ctx, stats)
    end
  end

  defp denied_by_policy?(nil, _tool_name), do: false
  defp denied_by_policy?(policy, tool_name), do: not ToolPolicy.allowed?(policy, tool_name)

  defp execute(id, tool_name, params, ctx, stats) do
    tool = Map.fetch!(ctx.tools, tool_name)
    inner = fn -> run_inner(tool, id, params, ctx.signal) end
    approval? = approval_required?(ctx, tool_name)

    # The approval layer is wrapped too: nothing on the call path may take the
    # pump down, or the script would block forever on a response that is never
    # written.
    result =
      guarded(fn ->
        if approval? do
          ToolExecutor.execute_with_approval(tool_name, params, inner, ctx.approval_context)
        else
          inner.()
        end
      end)

    case normalize(result, approval?) do
      {:approval_blocked, phrase} ->
        respond_error(ctx, id, "#{phrase} for '#{tool_name}'")
        %{stats | denied: stats.denied + 1}

      {:error, message} ->
        respond_error(ctx, id, message)
        %{stats | errors: stats.errors + 1}

      {:ok, content} ->
        account(id, tool_name, content, ctx, stats)
    end
  end

  defp approval_required?(%{tool_policy: nil}, _tool_name), do: false
  defp approval_required?(%{approval_context: nil}, _tool_name), do: false

  defp approval_required?(ctx, tool_name),
    do: ToolPolicy.requires_approval?(ctx.tool_policy, tool_name)

  defp account(id, tool_name, content, ctx, stats) do
    size = byte_size(content)
    remaining = ctx.max_result_bytes - stats.bytes

    if size > remaining do
      respond_error(
        ctx,
        id,
        "rpc result byte budget exceeded (result #{size} bytes, #{remaining} bytes remaining of #{ctx.max_result_bytes})"
      )

      %{stats | errors: stats.errors + 1}
    else
      respond_ok(ctx, id, content)

      %{
        stats
        | bytes: stats.bytes + size,
          tools_used: MapSet.put(stats.tools_used, tool_name)
      }
    end
  end

  defp run_inner(tool, id, params, signal) do
    tool.execute.("exec_code_rpc_#{id}", params, signal, nil)
  end

  # An inner tool that raises or throws must never take the pump down with it:
  # the script gets a ToolError and keeps running.
  defp guarded(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, value -> {:error, "#{kind}: #{inspect(value)}"}
  end

  defp normalize(%AgentToolResult{} = result, approval?) do
    case approval? && approval_block_reason(result.details) do
      phrase when is_binary(phrase) -> {:approval_blocked, phrase}
      _ -> {:ok, content_text(result.content)}
    end
  end

  defp normalize({:ok, %AgentToolResult{} = result}, approval?), do: normalize(result, approval?)
  defp normalize({:ok, text}, _approval?) when is_binary(text), do: {:ok, text}
  defp normalize({:ok, other}, _approval?), do: {:ok, inspect(other)}
  defp normalize({:error, reason}, _approval?) when is_binary(reason), do: {:error, reason}
  defp normalize({:error, reason}, _approval?), do: {:error, inspect(reason)}
  defp normalize(other, _approval?), do: {:ok, inspect(other)}

  defp approval_block_reason(details) when is_map(details) do
    cond do
      Map.get(details, :denied) == true -> "approval denied"
      Map.get(details, :timeout) == true -> "approval timed out"
      Map.has_key?(details, :approval_error) -> "approval failed"
      true -> nil
    end
  end

  defp approval_block_reason(_details), do: nil

  defp content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %TextContent{text: text} when is_binary(text) -> text
      _ -> "[non-text content omitted]"
    end)
    |> Enum.join("\n")
  end

  defp content_text(_), do: ""

  defp respond_ok(ctx, id, content) do
    write_response(ctx.rpc_dir, id, %{"id" => id, "ok" => true, "content" => content})
  end

  defp respond_error(ctx, id, message) do
    write_response(ctx.rpc_dir, id, %{"id" => id, "ok" => false, "error" => message})
  end

  defp write_response(rpc_dir, id, payload) do
    final = response_path(rpc_dir, id)
    tmp = final <> ".tmp"

    File.write!(tmp, Jason.encode!(payload))
    File.rename!(tmp, final)
    :ok
  rescue
    error ->
      Logger.warning("execute_code rpc response write failed: #{Exception.message(error)}")
      :ok
  end

  defp request_path(rpc_dir, id), do: Path.join(rpc_dir, "req-#{id}.json")
  defp response_path(rpc_dir, id), do: Path.join(rpc_dir, "res-#{id}.json")
end
