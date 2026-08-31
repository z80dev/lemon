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

  ## Result-channel files

  Besides `req-*.json` frames the rpc directory carries two script-authored
  file kinds, both published with the same atomic tmp+rename discipline:

    * `text-<n>.json` — the `text()` result blocks. They are never seen by the
      pump; `read_text_blocks/2` collects them after the run (or after a
      timeout/abort kill), which is what makes deliberate results survive a
      kill that discards partially captured stdout.
    * `notify-<n>.json` — the `notify()` streaming side channel. Every sweep
      consumes them (read + delete, the same hygiene as requests) and forwards
      each message through the ctx's `:on_update` callback as a partial tool
      update, capped at 4 KiB per message and 64 messages per run (the
      `@notify_*` constants below); anything beyond is silently
      dropped, and a nil callback consumes without forwarding so the files can
      never accumulate.

  ## Concurrency

  One sweep claims requests serially — parse, authenticate, replay-check, and
  call-budget reservation all happen in the sweeping process in ascending id
  order, so accounting stays exact — and then dispatches the claimed,
  policy-allowed tool calls in bounded parallel waves of `:max_parallel_rpc`
  supervised tasks (see `dispatch_claimed/3` for why the tasks are linked and
  which supervisor owns them). Responses stay atomic per id, so ordering
  between requests never matters.
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
  @default_max_parallel_rpc 4

  # notify() forwarding caps: bytes are per message, the second is per run.
  # Both are deliberately generous for a human-readable progress channel and
  # deliberately small against a hostile flood.
  @notify_message_max_bytes 4_096
  @notify_max_per_run 64
  # A shim-written notify frame is ASCII JSON around one message, so anything
  # this large is not shim-written; it is dropped without being read.
  @notify_file_max_bytes 65_536

  # Must match `Config`'s `@default_max_text_bytes`; pinned by tests. Used only
  # when `read_text_blocks/2` is called without an explicit budget.
  @default_max_text_bytes 65_536
  # JSON envelope ({"n": 123, "text": ...}) around a block's text.
  @text_block_envelope_slack 256

  @typedoc """
  One authenticated, policy-allowed request claimed by a sweep, awaiting
  parallel dispatch.
  """
  @type claim :: %{
          required(:id) => integer(),
          required(:tool) => String.t(),
          required(:params) => map(),
          required(:approval?) => boolean()
        }

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
          optional(:max_requests_per_sweep) => pos_integer(),
          optional(:max_parallel_rpc) => pos_integer(),
          optional(:on_update) => (AgentToolResult.t() -> :ok) | nil
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
  files without reprocessing the head. `notify-*.json` files are consumed and
  forwarded on the same polls.

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
  tool dispatch. Claimed requests are dispatched in parallel waves of at most
  `:max_parallel_rpc` (default #{@default_max_parallel_rpc}) supervised tasks.

  This is the shared polling entry point for the persistent-cell RPC server.
  """
  @spec process_pending(ctx(), stats()) :: stats()
  def process_pending(ctx, stats) do
    collect_notifications(ctx)

    {stats, claimed} =
      ctx.rpc_dir
      |> pending_requests(max_requests_per_sweep(ctx))
      |> Enum.reduce({stats, []}, fn {id, path}, {acc, claimed} ->
        claim_request(id, path, ctx, acc, claimed)
      end)

    dispatch_claimed(claimed, ctx, stats)
  end

  @doc """
  Consume and process one request id through the complete authenticated path.

  The function is intentionally reusable by a server that owns polling and
  lifecycle itself. Invalid or denied requests are always answered in writing.
  """
  @spec process_request(integer(), ctx(), stats()) :: stats()
  def process_request(id, ctx, stats) when is_integer(id) do
    {stats, claimed} = claim_request(id, request_path(ctx.rpc_dir, id), ctx, stats, [])
    dispatch_claimed(claimed, ctx, stats)
  end

  @doc """
  Read the `text-<n>.json` result blocks a script flushed into `rpc_dir`, in
  ascending block order.

  This runs *after* the script task is over (normally, timed out, or killed):
  blocks are written through per `text()` call, so whatever the script flushed
  before it died is exactly what lands in the tool result. Blocks are left in
  place for the rpc directory's normal teardown.

  Defensive posture (the files are script-authored): anything that is not a
  regular file — a planted symlink, like the `res-<id>.json` defense — any
  frame larger than the whole byte budget plus its JSON envelope, any
  undecodable body, and any block that would push the accumulated total past
  `max_text_bytes` (default #{@default_max_text_bytes}) is skipped without
  crashing.
  """
  @spec read_text_blocks(String.t(), keyword()) :: [String.t()]
  def read_text_blocks(rpc_dir, opts \\ []) when is_binary(rpc_dir) do
    max_bytes = Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)

    {blocks, _bytes} =
      rpc_dir
      |> text_block_paths()
      |> Enum.reduce({[], 0}, fn {_id, path}, {acc, bytes} ->
        case read_text_block(path, bytes, max_bytes) do
          {:ok, text, size} -> {[text | acc], bytes + size}
          :skip -> {acc, bytes}
        end
      end)

    Enum.reverse(blocks)
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

  defp max_parallel_rpc(ctx) do
    case Map.get(ctx, :max_parallel_rpc, @default_max_parallel_rpc) do
      max_parallel_rpc when is_integer(max_parallel_rpc) and max_parallel_rpc > 0 ->
        max_parallel_rpc

      _ ->
        @default_max_parallel_rpc
    end
  end

  # ==========================================================================
  # Notification side channel (notify-*.json)
  # ==========================================================================

  defp collect_notifications(ctx) do
    ctx.rpc_dir
    |> Path.join("notify-*.json")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      case Integer.parse(Path.basename(path, ".json") |> String.replace_prefix("notify-", "")) do
        {n, ""} -> {n, path}
        _ -> {:invalid, path}
      end
    end)
    |> Enum.sort_by(fn
      {n, path} when is_integer(n) -> {0, n, path}
      {:invalid, path} -> {1, path}
    end)
    |> Enum.reduce(0, fn
      {n, path}, forwarded when is_integer(n) ->
        message = read_notification(path)
        # Consume first, always: a notification nobody can forward must still
        # be removed so the directory cannot accumulate them.
        consume_request(path)

        if forwarded < @notify_max_per_run do
          forward_notification(Map.get(ctx, :on_update), message)
          forwarded + 1
        else
          forwarded
        end

      {:invalid, path}, forwarded ->
        consume_request(path)
        forwarded
    end)

    :ok
  end

  # Reads one notification frame, or nil when it is not a regular file, is
  # larger than anything the shim would write, or does not decode to a
  # `{"msg": binary}` body. Undecodable frames are dropped silently.
  defp read_notification(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @notify_file_max_bytes <-
           File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"msg" => msg}} when is_binary(msg) <- Jason.decode(body) do
      cap_message_bytes(msg, @notify_message_max_bytes)
    else
      _ -> nil
    end
  end

  defp forward_notification(nil, _message), do: :ok

  defp forward_notification(on_update, message) do
    # A broken streaming callback must never take a sweep down with it: the
    # notification is advisory, the requests in the same sweep are not.
    on_update.(%AgentToolResult{content: [%TextContent{text: "notify: " <> (message || "")}]})
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  # Byte-cap on a valid codepoint boundary: python's json.dump escapes
  # non-ASCII by default, so the common case is plain ASCII, but a hand-built
  # frame may end mid-codepoint after binary_part/3.
  defp cap_message_bytes(message, max_bytes) when byte_size(message) <= max_bytes, do: message

  defp cap_message_bytes(message, max_bytes) do
    message |> binary_part(0, max_bytes) |> chomp_invalid_trailing()
  end

  defp chomp_invalid_trailing(part) when byte_size(part) == 0, do: part

  defp chomp_invalid_trailing(part) do
    case :unicode.characters_to_binary(part, :utf8, :utf8) do
      fixed when is_binary(fixed) -> fixed
      _invalid_or_error -> chomp_invalid_trailing(binary_part(part, 0, byte_size(part) - 1))
    end
  end

  # ==========================================================================
  # Text result blocks (text-*.json)
  # ==========================================================================

  defp text_block_paths(rpc_dir) do
    rpc_dir
    |> Path.join("text-*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Integer.parse(Path.basename(path, ".json") |> String.replace_prefix("text-", "")) do
        {n, ""} -> [{n, path}]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  defp read_text_block(path, accumulated, max_bytes) do
    with {:ok, %File.Stat{type: :regular, size: size}}
         when size <= max_bytes + @text_block_envelope_slack <- File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"text" => text}} when is_binary(text) <- Jason.decode(body),
         :ok <- within_budget(text, accumulated, max_bytes) do
      {:ok, text, byte_size(text)}
    else
      _ -> :skip
    end
  end

  defp within_budget(text, accumulated, max_bytes)
       when accumulated + byte_size(text) <= max_bytes,
       do: :ok

  defp within_budget(_text, _accumulated, _max_bytes), do: :error

  # ==========================================================================
  # Claiming (serial, in the sweeping process)
  # ==========================================================================

  # Claiming keeps every stats mutation in the single process that runs the
  # sweep, in ascending request id order. That is what keeps replay detection
  # (`seen?/2`) and the `max_calls` budget exact under parallel dispatch: an id
  # is remembered, and a call slot is reserved, before any task starts, so two
  # concurrent sweeps can never double-dispatch one id and the budget can never
  # be overshot by racing claims. (Sweeps themselves never overlap: serve/2
  # polls sequentially and RpcServer awaits each sweep task before rescheduling.)
  defp claim_request(id, request, ctx, stats, claimed) do
    if response_present?(response_path(ctx.rpc_dir, id)) do
      consume_request(request)
      {remember_id(stats, id), claimed}
    else
      parsed = parse_request(request)
      consume_request(request)
      authenticate_and_claim(id, parsed, ctx, stats, claimed)
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

  defp authenticate_and_claim(id, {:ok, request}, ctx, stats, claimed) do
    if authenticated?(request, Map.get(ctx, :token)) do
      safely_claim_authenticated(id, request, ctx, stats, claimed)
    else
      authentication_failed(id, ctx, stats, claimed)
    end
  end

  defp authenticate_and_claim(id, :error, ctx, stats, claimed),
    do: authentication_failed(id, ctx, stats, claimed)

  defp authentication_failed(id, ctx, stats, claimed) do
    respond_error(ctx, id, @authentication_error)
    maybe_emit_bridge_denial(ctx)
    {%{stats | denied: stats.denied + 1}, claimed}
  end

  defp safely_claim_authenticated(id, request, ctx, stats, claimed) do
    claim_authenticated(id, request, ctx, stats, claimed)
  rescue
    _error ->
      respond_error(ctx, id, @unexpected_error)
      {stats |> remember_id(id) |> increment_errors(), claimed}
  catch
    _kind, _value ->
      respond_error(ctx, id, @unexpected_error)
      {stats |> remember_id(id) |> increment_errors(), claimed}
  end

  defp claim_authenticated(id, request, ctx, stats, claimed) do
    cond do
      seen?(stats, id) ->
        respond_error(ctx, id, @replay_error)
        {increment_errors(stats), claimed}

      stats.calls >= ctx.max_calls ->
        respond_error(
          ctx,
          id,
          "rpc call limit exceeded (max #{ctx.max_calls} calls per script)"
        )

        {stats |> remember_id(id) |> increment_errors(), claimed}

      true ->
        stats = stats |> remember_id(id) |> Map.update!(:calls, &(&1 + 1))

        case parse_call(request) do
          {:ok, tool_name, params} ->
            claim_tool(id, tool_name, params, ctx, stats, claimed)

          :error ->
            respond_error(ctx, id, @invalid_request_error)
            {increment_errors(stats), claimed}
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

  defp claim_tool(id, tool_name, params, ctx, stats, claimed) do
    cond do
      not Map.has_key?(ctx.tools, tool_name) ->
        respond_error(ctx, id, "tool '#{tool_name}' is not available inside execute_code scripts")
        {increment_errors(stats), claimed}

      denied_by_policy?(ctx.tool_policy, tool_name) ->
        reason =
          ToolPolicy.denial_reason(ctx.tool_policy, tool_name) ||
            "tool '#{tool_name}' denied by policy"

        respond_error(ctx, id, reason)
        {%{stats | denied: stats.denied + 1}, claimed}

      true ->
        claim = %{
          id: id,
          tool: tool_name,
          params: params,
          approval?: approval_required?(ctx, tool_name)
        }

        {stats, [claim | claimed]}
    end
  end

  defp denied_by_policy?(nil, _tool_name), do: false
  defp denied_by_policy?(policy, tool_name), do: not ToolPolicy.allowed?(policy, tool_name)

  # ==========================================================================
  # Parallel dispatch
  # ==========================================================================

  # Claimed requests are dispatched as supervised tasks in waves of at most
  # `max_parallel_rpc`, awaited by the sweeping process.
  #
  # Supervisor choice: the existing `CodingAgent.TaskSupervisor` already owns
  # every other execute_code task (script task, session facade, RpcServer sweep
  # tasks); these are the same kind of short-lived, isolated work, and a
  # dedicated supervisor would add process-tree surface without changing any
  # failure semantics.
  #
  # Link choice: tasks are started with `Task.Supervisor.async/2` (linked to
  # the sweeping process), not `async_nolink/2`. A killed sweep — abort,
  # caller death, server stop — therefore tears down its in-flight tool tasks
  # exactly like the previous inline execution, leaving no orphaned approvals
  # or tool side effects. The converse (a crashed task killing the sweep) is
  # contained twice: `guarded/1` already converts raises/throws/exits from the
  # tool and approval path into error responses, and RpcServer's sweep
  # containment keeps the previous stats when a sweep dies any other way.
  #
  # Approvals stay on the existing `ToolExecutor.execute_with_approval/4` path,
  # inside each task. That path is function-call based with no process-affine
  # state: `approval_request_fun` (or `LemonCore.ExecApprovals.request/1`)
  # serializes through its own ETS/PubSub store, so each of N concurrent
  # gated calls produces exactly one prompt request — never duplicated, never
  # lost — and a pre-existing approval satisfies concurrent requests without
  # prompting again.
  #
  # Accounting stays serial: only the tool execution (the slow part) is
  # parallel; the result-byte budget check and the atomic response write
  # happen in the sweeping process as each task returns, so two concurrent
  # results cannot both spend the same remaining bytes.
  defp dispatch_claimed([], _ctx, stats), do: stats

  defp dispatch_claimed(claimed, ctx, stats) do
    claimed
    |> Enum.reverse()
    |> Enum.chunk_every(max_parallel_rpc(ctx))
    |> Enum.reduce(stats, fn wave, acc -> run_wave(wave, ctx, acc) end)
  end

  defp run_wave(wave, ctx, stats) do
    wave
    |> Enum.map(fn claim ->
      task = Task.Supervisor.async(CodingAgent.TaskSupervisor, fn -> run_claim(claim, ctx) end)
      {claim, task}
    end)
    |> Enum.reduce(stats, fn {claim, task}, acc -> await_claim(claim, task, ctx, acc) end)
  end

  # Runs in the task process: everything up to (but not including) the
  # result-byte accounting and the response write, both of which stay with the
  # sweeping process.
  defp run_claim(claim, ctx) do
    tool = Map.fetch!(ctx.tools, claim.tool)
    inner = fn -> run_inner(tool, claim.id, claim.params, ctx.signal) end

    # The approval layer is wrapped too: nothing on the call path may take the
    # task down, or the script would block forever on a response that is never
    # written.
    guarded(fn ->
      if claim.approval? do
        ToolExecutor.execute_with_approval(claim.tool, claim.params, inner, ctx.approval_context)
      else
        inner.()
      end
    end)
    |> normalize(claim.approval?)
  end

  defp await_claim(claim, task, ctx, stats) do
    outcome = await_task(task)

    case outcome do
      {:approval_blocked, phrase} ->
        respond_error(ctx, claim.id, "#{phrase} for '#{claim.tool}'")
        %{stats | denied: stats.denied + 1}

      {:error, message} ->
        respond_error(ctx, claim.id, message)
        increment_errors(stats)

      {:ok, content} ->
        account(claim.id, claim.tool, content, ctx, stats)
    end
  end

  defp await_task(task) do
    case Task.yield(task, :infinity) do
      {:ok, outcome} -> outcome
      {:exit, _reason} -> {:error, @unexpected_error}
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
