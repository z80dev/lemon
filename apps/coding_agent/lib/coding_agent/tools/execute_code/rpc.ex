defmodule CodingAgent.Tools.ExecuteCode.Rpc do
  @moduledoc """
  The authenticated file-RPC pump shared by isolated and persistent Python
  execution.

  Requests and responses live only in a fresh, private directory. Every request
  must carry the directory's configured token; authentication happens before a
  request can consume a call or result-byte budget or reach tool lookup. A
  completed request is consumed, and responses are published atomically with a
  temporary file followed by rename.

  `serve/2` must run in the process that started the task because `Task.yield/2`
  requires task ownership. Persistent cells use `process_pending/2` to run the
  same parsing, authentication, policy, approval, dispatch, and accounting path.
  """

  require Logger

  alias CodingAgent.PrivateTmp
  alias CodingAgent.ToolExecutor
  alias CodingAgent.ToolPolicy
  alias CodingAgent.PythonRepl.Telemetry
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @authentication_error "rpc authentication failed"
  @invalid_request_error "invalid rpc request"
  @replay_error "rpc request already processed"
  @unexpected_error "rpc request failed"

  @default_max_requests_per_sweep 100

  @type ctx :: %{
          required(:tools) => %{String.t() => LemonAgent.Types.AgentTool.t()},
          required(:tool_policy) => map() | nil,
          required(:approval_context) => map() | nil,
          required(:max_calls) => pos_integer(),
          required(:max_result_bytes) => pos_integer(),
          required(:signal) => reference() | nil,
          required(:rpc_dir) => String.t(),
          required(:token) => binary(),
          required(:poll_interval_ms) => pos_integer(),
          optional(:max_requests_per_sweep) => pos_integer()
        }

  @type stats :: %{
          calls: non_neg_integer(),
          denied: non_neg_integer(),
          errors: non_neg_integer(),
          bytes: non_neg_integer(),
          tools_used: MapSet.t(String.t()),
          seen_ids: MapSet.t(integer())
        }

  @doc """
  Returns zeroed pump statistics.
  """
  @spec initial_stats() :: stats()
  def initial_stats do
    %{
      calls: 0,
      denied: 0,
      errors: 0,
      bytes: 0,
      tools_used: MapSet.new(),
      seen_ids: MapSet.new()
    }
  end

  @doc """
  Serve RPC requests until the script task finishes.

  Each poll processes at most `:max_requests_per_sweep` requests (100 by
  default). Regular request files and symlinks are selected in ascending id
  order; request directories are skipped for workspace teardown. Each selected
  request is removed non-recursively after handling, including malformed and
  unauthenticated requests, so later polls continue through the remaining
  files without reprocessing the head.

  Returns `{:ok, task_result, stats}` when the task returned normally, or
  `{:exit, reason, stats}` when it died.
  """
  @spec serve(Task.t(), ctx()) :: {:ok | :exit, term(), stats()}
  def serve(%Task{} = task, ctx) do
    loop(task, ctx, initial_stats())
  end

  @doc """
  Process one bounded snapshot of pending requests and return updated statistics.

  At most `:max_requests_per_sweep` regular request files or symlinks are
  selected in ascending id order (100 by default); directories are skipped.
  Each selected request is removed non-recursively after handling whether it
  authenticates or not, so the next sweep continues with the remaining ids.
  Authentication still occurs after selection, before any budget accounting or
  tool dispatch.

  This is the shared polling entry point for the persistent-cell RPC server.
  """
  @spec process_pending(ctx(), stats()) :: stats()
  def process_pending(ctx, stats) do
    ctx.rpc_dir
    |> pending_requests(max_requests_per_sweep(ctx))
    |> Enum.reduce(stats, fn {id, path}, acc -> process_request_path(id, path, ctx, acc) end)
  end

  @doc """
  Consume and process one request id through the complete authenticated path.

  The function is intentionally reusable by a server that owns polling and
  lifecycle itself. Invalid or denied requests are always answered in writing.
  """
  @spec process_request(integer(), ctx(), stats()) :: stats()
  def process_request(id, ctx, stats) when is_integer(id) do
    process_request_path(id, request_path(ctx.rpc_dir, id), ctx, stats)
  end

  @doc false
  @spec authenticated?(map(), binary() | nil) :: boolean()
  def authenticated?(%{"token" => provided}, expected)
      when is_binary(provided) and is_binary(expected) and byte_size(expected) > 0 do
    byte_size(provided) == byte_size(expected) and :crypto.hash_equals(provided, expected)
  end

  def authenticated?(_request, _expected), do: false

  @doc false
  @spec request_path(String.t(), integer()) :: String.t()
  def request_path(rpc_dir, id), do: Path.join(rpc_dir, "req-#{id}.json")

  @doc false
  @spec response_path(String.t(), integer()) :: String.t()
  def response_path(rpc_dir, id), do: Path.join(rpc_dir, "res-#{id}.json")

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
        loop(task, ctx, process_pending(ctx, stats))
    end
  end

  defp pending_requests(rpc_dir, max_requests_per_sweep) do
    rpc_dir
    |> Path.join("req-*.json")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      case Integer.parse(Path.basename(path, ".json") |> String.replace_prefix("req-", "")) do
        {id, ""} -> {:request, id, path}
        _ -> {:invalid, path}
      end
    end)
    |> Enum.filter(fn
      {:request, _id, path} -> request_file?(path)
      {:invalid, path} -> request_file?(path)
    end)
    |> Enum.sort_by(fn
      {:request, id, path} -> {0, id, path}
      {:invalid, path} -> {1, path}
    end)
    |> Enum.take(max_requests_per_sweep)
    |> Enum.flat_map(fn
      {:request, id, path} -> [{id, path}]
      {:invalid, path} -> consume_request(path) && []
    end)
  end

  defp request_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] -> true
      _ -> false
    end
  end

  defp max_requests_per_sweep(ctx) do
    case Map.get(ctx, :max_requests_per_sweep, @default_max_requests_per_sweep) do
      max_requests_per_sweep
      when is_integer(max_requests_per_sweep) and max_requests_per_sweep > 0 ->
        max_requests_per_sweep

      _ ->
        @default_max_requests_per_sweep
    end
  end

  defp process_request_path(id, request, ctx, stats) do
    if response_present?(response_path(ctx.rpc_dir, id)) do
      consume_request(request)
      remember_id(stats, id)
    else
      parsed = parse_request(request)
      consume_request(request)
      authenticate_and_process(id, parsed, ctx, stats)
    end
  end

  # Only a regular file published by the atomic rename counts as an answered
  # id. `File.exists?/1` follows symlinks, so a planted `res-<id>.json`
  # symlink must not masquerade as an already-written response and swallow
  # the request; the responder replaces such a link instead of following it.
  defp response_present?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp parse_request(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp authenticate_and_process(id, {:ok, request}, ctx, stats) do
    if authenticated?(request, Map.get(ctx, :token)) do
      safely_process_authenticated(id, request, ctx, stats)
    else
      authentication_failed(id, ctx, stats)
    end
  end

  defp authenticate_and_process(id, :error, ctx, stats),
    do: authentication_failed(id, ctx, stats)

  defp authentication_failed(id, ctx, stats) do
    respond_error(ctx, id, @authentication_error)
    maybe_emit_bridge_denial(ctx)
    %{stats | denied: stats.denied + 1}
  end

  defp safely_process_authenticated(id, request, ctx, stats) do
    process_authenticated(id, request, ctx, stats)
  rescue
    _error ->
      respond_error(ctx, id, @unexpected_error)
      stats |> remember_id(id) |> increment_errors()
  catch
    _kind, _value ->
      respond_error(ctx, id, @unexpected_error)
      stats |> remember_id(id) |> increment_errors()
  end

  defp process_authenticated(id, request, ctx, stats) do
    cond do
      seen?(stats, id) ->
        respond_error(ctx, id, @replay_error)
        increment_errors(stats)

      stats.calls >= ctx.max_calls ->
        respond_error(
          ctx,
          id,
          "rpc call limit exceeded (max #{ctx.max_calls} calls per script)"
        )

        stats |> remember_id(id) |> increment_errors()

      true ->
        stats = stats |> remember_id(id) |> Map.update!(:calls, &(&1 + 1))

        case parse_call(request) do
          {:ok, tool_name, params} ->
            run_tool(id, tool_name, params, ctx, stats)

          :error ->
            respond_error(ctx, id, @invalid_request_error)
            increment_errors(stats)
        end
    end
  end

  defp parse_call(%{"tool" => tool} = request) when is_binary(tool) do
    case Map.get(request, "params") || %{} do
      params when is_map(params) -> {:ok, tool, params}
      _ -> :error
    end
  end

  defp parse_call(_request), do: :error

  defp run_tool(id, tool_name, params, ctx, stats) do
    cond do
      not Map.has_key?(ctx.tools, tool_name) ->
        respond_error(ctx, id, "tool '#{tool_name}' is not available inside execute_code scripts")
        increment_errors(stats)

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
        increment_errors(stats)

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

      increment_errors(stats)
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

  defp maybe_emit_bridge_denial(ctx) do
    if Map.get(ctx, :persistent_repl?) == true, do: Telemetry.bridge_denied(:authentication)
  end

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

  # The response body is reserved as a private 0600 file (hidden, random
  # name) and published by same-directory rename: a half-written response is
  # never visible under `res-<id>.json`, the published inode is owner-only,
  # and a planted symlink at the final name is replaced, not followed.
  defp write_response(rpc_dir, id, payload) do
    name = "res-#{id}.json"

    try do
      case PrivateTmp.write_file(rpc_dir, name, Jason.encode!(payload)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("execute_code rpc response write failed: #{inspect(reason)}")
          :ok
      end
    rescue
      error ->
        Logger.warning("execute_code rpc response write failed: #{Exception.message(error)}")
        :ok
    end
  end

  # Never recurse through a request path. If selection races with replacement
  # by a directory, File.rm/1 returns :eisdir and the directory remains for
  # workspace teardown.
  defp consume_request(path) do
    _ = File.rm(path)
    :ok
  end

  defp seen?(stats, id), do: MapSet.member?(Map.get(stats, :seen_ids, MapSet.new()), id)

  defp remember_id(stats, id) do
    Map.put(stats, :seen_ids, MapSet.put(Map.get(stats, :seen_ids, MapSet.new()), id))
  end

  defp increment_errors(stats), do: %{stats | errors: stats.errors + 1}
end
