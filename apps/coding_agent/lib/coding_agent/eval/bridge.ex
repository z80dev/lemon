defmodule CodingAgent.Eval.Bridge do
  @moduledoc """
  Runs the session tool calls one `eval` cell makes through `tools.<name>(args)`.

  The `eval` tool process owns one bridge per cell and feeds it the slot's
  `{:tool_call, call, tool, args}` notifications. Each admitted call runs in an
  unlinked `CodingAgent.TaskSupervisor` task with its own abort signal: the
  task resolves the tool through the resolver (the session's frozen,
  policy/approval/hook-wrapped catalog by default), validates its arguments
  through the disclosure bridge's schema check without consuming provider-only
  intent metadata (cell arguments are ordinary data, including `"i"`/`"node"`)
  and answers through the configured reply module's `tool_reply/4` callback.

  At most 16 calls run at once; later ones wait FIFO. A cell may make at most
  1,000 calls. When the cell ends, times out or is aborted, `shutdown/1`
  aborts every outstanding call, waits a short grace and kills what remains, so
  no inner call outlives the cell. A task also dies with the `eval` process.

  Mutation locks: `eval` runs under the session mutation lock, and inner
  mutating tools take that same lock from their task. Tasks therefore inherit
  the caller's `{:session, _}` keys (`CodingAgent.MutationLock.inherit/2`): inner
  mutations still run one at a time among themselves, without waiting on the
  cell's own lock. This is sound because `shutdown/1` returns only after every
  task has exited, before the caller's lock is released.

  Each call resolves in the cell to `%{ok, text, details, images}`: `text` joins
  the result's text blocks (bounded to 1 MiB), `details` is a JSON-safe
  projection of the result details (dropped above 64 KiB) and `images` holds
  base64 `%{mimeType, data}` blocks (4 MiB in total). A resolver refusal or
  invalid arguments reject the call in the cell instead.

  `new/5` accepts `:reply_module` (default `CodingAgent.Eval.Kernel`), whose
  `tool_reply/4` callback receives replies. `call/5` resolves a wrapped tool,
  prepares arguments through the normal agent schema validator, and returns
  `{:ok, envelope}` or `{:error, refusal}` without bypassing tool wrappers.
  Authentic structured shell fields are promoted from details when available;
  human-readable output is never parsed. A merged backend reports `output`,
  `output_combined: true` and null `stdout`/`stderr`: null means unavailable,
  not empty. Exit status remains independently available.
  """

  alias CodingAgent.Eval.Kernel
  alias CodingAgent.ExecutionNode.Codec
  alias CodingAgent.MutationLock
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{ImageContent, TextContent}

  @max_running 16
  @max_calls 1_000
  @max_text_bytes 1_048_576
  @max_details_bytes 65_536
  @max_image_bytes 4 * 1_048_576
  @shutdown_grace_ms 2_000

  @type resolver :: (String.t() -> {:ok, AgentTool.t()} | {:error, String.t()})

  @type t :: %__MODULE__{
          slot: GenServer.server(),
          ref: reference(),
          cell: String.t(),
          resolver: resolver() | nil,
          reply_module: module(),
          locks: [MutationLock.key()],
          running: %{reference() => map()},
          queue: :queue.queue(),
          calls: non_neg_integer(),
          closed: boolean()
        }

  defstruct [
    :slot,
    :ref,
    :cell,
    :resolver,
    reply_module: Kernel,
    locks: [],
    running: %{},
    queue: :queue.new(),
    calls: 0,
    closed: false
  ]

  @doc """
  A bridge for run `ref` of `slot`. `cell` labels inner tool call ids
  (`"eval_<cell>_<n>"`). Session locks held by the caller are inherited by
  inner calls.
  """
  @spec new(GenServer.server(), reference(), String.t(), resolver() | nil, keyword()) :: t()
  def new(slot, ref, cell, resolver, opts \\ []) do
    %__MODULE__{
      slot: slot,
      ref: ref,
      cell: cell,
      resolver: resolver,
      reply_module: Keyword.get(opts, :reply_module, Kernel),
      locks: Enum.filter(MutationLock.held(), &match?({:session, _}, &1))
    }
  end

  @doc "Admit, queue or refuse tool call `call` from the cell."
  @spec request(t(), pos_integer(), String.t(), term()) :: t()
  def request(%__MODULE__{} = bridge, call, tool, args) do
    cond do
      bridge.closed ->
        refuse(bridge, call, "the cell is finishing; no new tool calls are accepted")

      bridge.resolver == nil ->
        refuse(bridge, call, "session tools are not available to this eval kernel")

      bridge.calls >= @max_calls ->
        refuse(bridge, call, "a cell may make at most #{@max_calls} tool calls")

      not is_map(args) ->
        refuse(bridge, call, "arguments must be an object")

      map_size(bridge.running) < @max_running ->
        start(%{bridge | calls: bridge.calls + 1}, {call, tool, args})

      true ->
        %{bridge | calls: bridge.calls + 1, queue: :queue.in({call, tool, args}, bridge.queue)}
    end
  end

  @doc """
  Handles the `:DOWN` of the inner call task monitored by `monitor` (a key of
  `bridge.running`) and starts the next queued call.
  """
  @spec task_down(t(), reference(), term()) :: t()
  def task_down(%__MODULE__{} = bridge, monitor, reason) do
    {entry, running} = Map.pop!(bridge.running, monitor)

    if reason != :normal do
      # The task died before or while replying; a duplicate reply is ignored.
      bridge.reply_module.tool_reply(
        bridge.slot,
        bridge.ref,
        entry.call,
        {:ok, failure("tool #{entry.tool} exited: #{inspect(reason, limit: 10)}")}
      )
    end

    start_queued(%{bridge | running: running})
  end

  @doc """
  Stops accepting calls, refuses queued ones and signals running ones to abort,
  without waiting. Used before interrupting the kernel, so a cell awaiting tool
  calls can unwind.
  """
  @spec abort(t()) :: t()
  def abort(%__MODULE__{} = bridge) do
    for {call, _tool, _args} <- :queue.to_list(bridge.queue) do
      bridge.reply_module.tool_reply(
        bridge.slot,
        bridge.ref,
        call,
        {:error, "cancelled: the cell ended"}
      )
    end

    Enum.each(bridge.running, fn {_monitor, entry} -> AbortSignal.abort(entry.signal) end)
    %{bridge | closed: true, queue: :queue.new()}
  end

  @doc """
  Aborts every outstanding call and returns once each task has exited: after a
  #{@shutdown_grace_ms} ms grace the rest are killed.
  """
  @spec shutdown(t()) :: :ok
  def shutdown(%__MODULE__{} = bridge) do
    bridge = abort(bridge)
    deadline = System.monotonic_time(:millisecond) + @shutdown_grace_ms
    await_exits(bridge.running, deadline)
  end

  defp await_exits(running, _deadline) when map_size(running) == 0, do: :ok

  defp await_exits(running, deadline) do
    timeout =
      if deadline == :killed,
        do: :infinity,
        else: max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, monitor, :process, _pid, _reason} when is_map_key(running, monitor) ->
        {_entry, running} = Map.pop!(running, monitor)
        await_exits(running, deadline)
    after
      timeout ->
        Enum.each(running, fn {_monitor, entry} -> Process.exit(entry.pid, :kill) end)
        await_exits(running, :killed)
    end
  end

  defp refuse(bridge, call, message) do
    bridge.reply_module.tool_reply(bridge.slot, bridge.ref, call, {:error, message})
    bridge
  end

  defp start_queued(bridge) do
    with false <- bridge.closed,
         true <- map_size(bridge.running) < @max_running,
         {{:value, request}, queue} <- :queue.out(bridge.queue) do
      start(%{bridge | queue: queue}, request)
    else
      _ -> bridge
    end
  end

  defp start(bridge, {call, tool, args}) do
    %__MODULE__{
      slot: slot,
      ref: ref,
      resolver: resolver,
      locks: locks,
      reply_module: reply_module
    } = bridge

    signal = AbortSignal.new()
    tool_call_id = "eval_#{bridge.cell}_#{call}"
    owner = self()

    task = fn ->
      die_with(owner)
      MutationLock.inherit(locks, owner)
      reply_module.tool_reply(slot, ref, call, call(resolver, tool, tool_call_id, args, signal))
    end

    case Task.Supervisor.start_child(CodingAgent.TaskSupervisor, task) do
      {:ok, pid} ->
        entry = %{pid: pid, signal: signal, call: call, tool: tool}
        %{bridge | running: Map.put(bridge.running, Process.monitor(pid), entry)}

      {:error, reason} ->
        refuse(bridge, call, "could not start the tool call: #{inspect(reason)}")
    end
  end

  # Inherited locks are only valid while their holder lives: kill this task if
  # the `eval` process dies without running `shutdown/1`.
  defp die_with(owner) do
    task = self()

    spawn(fn ->
      owner_monitor = Process.monitor(owner)
      task_monitor = Process.monitor(task)

      receive do
        {:DOWN, ^owner_monitor, :process, _, _} ->
          Process.exit(task, :kill)

          receive do
            {:DOWN, ^task_monitor, :process, _, _} -> :ok
          end

        {:DOWN, ^task_monitor, :process, _, _} ->
          :ok
      end
    end)
  end

  @doc "Resolves and validates one wrapped tool call, preserving the generic result envelope."
  @spec call(resolver() | nil, String.t(), String.t(), term(), term()) ::
          {:ok, map()} | {:error, String.t()}
  def call(resolver, name, tool_call_id, args, signal)

  def call(nil, _name, _id, _args, _signal),
    do: {:error, "session tools are not available"}

  def call(_resolver, _name, _id, args, _signal) when not is_map(args),
    do: {:error, "arguments must be an object"}

  def call(resolver, name, tool_call_id, args, signal) do
    case resolve(resolver, name) do
      {:ok, %AgentTool{execute: execute} = tool} when is_function(execute, 4) ->
        case CodingAgent.ToolDisclosure.validate_args(args, tool.parameters) do
          :ok -> {:ok, execute_tool(execute, name, tool_call_id, args, signal)}
          {:error, errors} -> {:error, "invalid tool arguments: " <> Enum.join(errors, "; ")}
        end

      {:ok, _other} ->
        {:error, "unknown or unavailable tool: #{name}"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp resolve(resolver, name) do
    case resolver.(name) do
      {:ok, _tool} = ok -> ok
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, reason_text(reason)}
      _ -> {:error, "unknown or unavailable tool: #{name}"}
    end
  rescue
    error -> {:error, "could not resolve tool #{name}: #{Exception.message(error)}"}
  catch
    kind, reason ->
      {:error, "could not resolve tool #{name}: #{inspect({kind, reason}, limit: 10)}"}
  end

  defp execute_tool(execute, name, tool_call_id, args, signal) do
    project(execute.(tool_call_id, args, signal, nil))
  rescue
    error -> failure("tool #{name} raised: #{Exception.message(error)}")
  catch
    kind, reason -> failure("tool #{name} failed: #{inspect({kind, reason}, limit: 10)}")
  end

  # ── Result projection ────────────────────────────────────────────────────

  @doc false
  @spec project(term()) :: map()
  def project({:ok, %AgentToolResult{} = result}), do: project(result)
  def project({:error, reason}), do: failure(reason_text(reason))

  def project(%AgentToolResult{content: content} = result) do
    content = List.wrap(content)
    {images, omitted} = images(content)

    text =
      content
      |> Enum.flat_map(fn
        %TextContent{text: text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")
      |> then(fn text ->
        if omitted > 0,
          do: text <> "\n[#{omitted} image(s) omitted: image size limit reached]",
          else: text
      end)

    %{
      ok: result.is_error != true,
      text: bound_text(text),
      details: details(result.details),
      images: images
    }
    |> shell_fields(result.details)
  end

  def project(_other), do: failure("tool returned an unexpected result")

  defp shell_fields(envelope, details) when is_map(details) do
    Enum.reduce([:stdout, :stderr, :output, :exit_code, :output_combined], envelope, fn key,
                                                                                        acc ->
      case Map.fetch(details, key) do
        {:ok, value} ->
          Map.put(acc, key, shell_value(key, value))

        :error ->
          case Map.fetch(details, Atom.to_string(key)) do
            {:ok, value} -> Map.put(acc, key, shell_value(key, value))
            :error -> acc
          end
      end
    end)
  end

  defp shell_fields(envelope, _), do: envelope

  defp shell_value(key, value) when key in [:stdout, :stderr, :output] and is_binary(value),
    do: bound_text(value)

  defp shell_value(_key, value) when is_integer(value) or is_boolean(value) or is_nil(value),
    do: value

  defp shell_value(_key, _value), do: nil

  defp failure(text), do: %{ok: false, text: bound_text(text), details: nil, images: []}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason, limit: 20, printable_limit: 2_000)

  defp bound_text(text) do
    text = String.replace_invalid(text, "\uFFFD")

    if byte_size(text) <= @max_text_bytes do
      text
    else
      kept = text |> binary_part(0, @max_text_bytes) |> String.replace_invalid("")
      kept <> "\n[truncated: #{byte_size(text)} bytes total]"
    end
  end

  defp details(nil), do: nil

  defp details(value) do
    safe = Codec.json_safe(value)

    case Jason.encode(safe) do
      {:ok, json} when byte_size(json) <= @max_details_bytes -> safe
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp images(content) do
    {kept, _bytes, omitted} =
      Enum.reduce(content, {[], 0, 0}, fn
        %ImageContent{data: data, mime_type: mime}, {kept, bytes, omitted}
        when is_binary(data) ->
          if bytes + byte_size(data) <= @max_image_bytes,
            do: {[%{mimeType: mime, data: data} | kept], bytes + byte_size(data), omitted},
            else: {kept, bytes, omitted + 1}

        _block, acc ->
          acc
      end)

    {Enum.reverse(kept), omitted}
  end
end
