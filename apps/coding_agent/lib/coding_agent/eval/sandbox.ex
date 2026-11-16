defmodule CodingAgent.Eval.Sandbox do
  @moduledoc """
  Temporary session-owned Deno cell runtime for the opt-in code-mode profile.

  A cell has no OS permissions. Its bridge uses the session's wrapped resolver;
  it never inherits an outer mutation lock. Yield only detaches a waiter, not
  the cell or its tool tasks. The last cell's bounded result can be re-attached
  until another cell replaces it. Cells are volatile, not crash-replayable.
  """
  use GenServer, restart: :temporary

  alias CodingAgent.Eval.Bridge
  alias LemonAgent.AbortSignal

  @max_frame_bytes 1_048_576
  @max_output_bytes 50 * 1024
  @idle_timeout_ms 30 * 60 * 1000

  defstruct [
    :owner_pid,
    :owner_ref,
    :runtime,
    :port,
    :group,
    :os_pid,
    :cell_id,
    :ref,
    :bridge,
    :deadline,
    :idle,
    :signal,
    status: :idle,
    output: "",
    buffer: "",
    truncated: false,
    detached: false,
    pending_calls: [],
    waiters: %{}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def start_cell(slot, code, resolver, signal, timeout_ms),
    do: GenServer.call(slot, {:start, code, resolver, signal, timeout_ms}, :infinity)

  def attach(slot, cell_id, wait_ms, signal, resolver \\ nil),
    do: GenServer.call(slot, {:attach, cell_id, wait_ms, signal, resolver}, :infinity)

  def tool_reply(slot, ref, call, result),
    do: GenServer.cast(slot, {:tool_reply, ref, call, result})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.get(opts, :owner_pid)

    {:ok,
     arm_idle(%__MODULE__{
       runtime: Keyword.fetch!(opts, :runtime),
       owner_pid: owner,
       owner_ref: if(is_pid(owner), do: Process.monitor(owner))
     })}
  end

  @impl true
  def handle_call({operation, owner}, _from, state)
      when operation in [:bind_owner, :detach_owner],
      do: owner_reply(operation, owner, state)

  def handle_call(
        {:start, _code, _resolver, _signal, _timeout},
        _from,
        %{status: :running} = state
      ),
      do: {:reply, {:error, "a code-mode cell is already running; use eval_wait"}, state}

  def handle_call({:start, code, resolver, signal, timeout}, _from, state) do
    cancel_timer(state.idle)
    AbortSignal.unsubscribe(state.signal)
    AbortSignal.subscribe(signal)

    if AbortSignal.aborted?(signal) do
      {:reply, {:error, "cell cancelled before start"}, arm_idle(state)}
    else
      launch_cell(state, code, resolver, signal, timeout)
    end
  end

  def handle_call({:attach, id, wait_ms, signal, resolver}, from, %{cell_id: id} = state)
      when is_binary(id) do
    if AbortSignal.aborted?(signal) do
      state = finish(state, :aborted, "cell cancelled")
      {:reply, snapshot(state), state}
    else
      state = resume_calls(state, resolver)
      attach_waiter(state, from, wait_ms, signal)
    end
  end

  def handle_call({:attach, _id, _wait, _signal, _resolver}, _from, state),
    do: {:reply, {:error, "unknown code-mode cell in this session"}, state}

  @impl true
  def handle_cast({:tool_reply, ref, call, result}, %{ref: ref, port: port} = state)
      when is_port(port) do
    frame =
      case result do
        {:ok, value} -> %{type: "reply", call: call, result: value}
        {:error, error} -> %{type: "reply", call: call, error: error}
      end

    Port.command(port, Jason.encode!(frame) <> "\n")
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, consume(%{state | buffer: state.buffer <> data})}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:noreply, finish(state, :error, "sandbox exited with status #{status}")}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:noreply, finish(state, :error, "sandbox exited: #{inspect(reason)}")}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{bridge: bridge} = state)
      when not is_nil(bridge) do
    if Map.has_key?(bridge.running, monitor),
      do: {:noreply, %{state | bridge: Bridge.task_down(bridge, monitor, reason)}},
      else: {:noreply, state}
  end

  def handle_info({:yield, token}, state) do
    case Map.pop(state.waiters, token) do
      {nil, _waiters} ->
        {:noreply, state}

      {{from, _timer, signal}, waiters} ->
        if signal != state.signal, do: AbortSignal.unsubscribe(signal)
        GenServer.reply(from, snapshot(state))
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:deadline, ref}, %{ref: ref} = state),
    do: {:noreply, finish(state, :timeout, "cell deadline exceeded")}

  def handle_info({:lemon_abort, signal, :abort}, state) do
    if signal == state.signal or Enum.any?(state.waiters, fn {_, {_, _, s}} -> s == signal end),
      do: {:noreply, finish(state, :aborted, "cell cancelled")},
      else: {:noreply, state}
  end

  def handle_info({:idle, token}, %{idle: {token, _timer}} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  defp launch_cell(state, code, resolver, signal, timeout) do
    id = "cell_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    ref = make_ref()
    driver = Application.app_dir(:coding_agent, "priv/eval/code_mode.js")

    args = [
      "run",
      "--no-prompt",
      "--no-config",
      "--no-remote",
      "--unstable-worker-options",
      "--no-npm",
      "--deny-read",
      "--deny-write",
      "--deny-net",
      "--deny-env",
      "--deny-run",
      "--deny-ffi",
      "--deny-sys",
      driver
    ]

    port =
      LemonCore.NativeProcess.open(
        {:spawn_executable, state.runtime},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide, {:args, args}]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    group =
      case LemonCore.ProcessGroup.capture_workload_group(os_pid) do
        {:ok, group} ->
          group

        {:error, _reason} ->
          LemonCore.ProcessGroup.terminate(os_pid, signal: :sigkill)
          close_port(port)
          raise "could not establish sandbox process ownership"
      end

    Port.command(port, Jason.encode!(%{type: "run", code: code}) <> "\n")

    state = %{
      state
      | port: port,
        os_pid: os_pid,
        group: group,
        cell_id: id,
        ref: ref,
        bridge: Bridge.new(self(), ref, id, resolver, reply_module: __MODULE__),
        signal: signal,
        status: :running,
        output: "",
        buffer: "",
        truncated: false,
        deadline: Process.send_after(self(), {:deadline, ref}, timeout),
        idle: nil,
        waiters: %{},
        detached: false,
        pending_calls: []
    }

    {:reply, {:ok, id}, state}
  rescue
    _error -> {:reply, {:error, "could not start permissionless Deno runtime"}, arm_idle(state)}
  end

  defp attach_waiter(%{status: :running} = state, from, wait_ms, signal) when wait_ms > 0 do
    AbortSignal.subscribe(signal)
    token = make_ref()
    timer = Process.send_after(self(), {:yield, token}, wait_ms)
    {:noreply, %{state | waiters: Map.put(state.waiters, token, {from, timer, signal})}}
  end

  defp attach_waiter(state, _from, _wait_ms, _signal), do: {:reply, snapshot(state), state}

  defp consume(state) do
    case :binary.match(state.buffer, "\n") do
      {offset, 1} when offset <= @max_frame_bytes ->
        <<line::binary-size(^offset), "\n", rest::binary>> = state.buffer
        state = %{state | buffer: rest}

        case Jason.decode(line) do
          {:ok, frame} -> consume_frame(state, frame)
          {:error, _} -> finish(state, :error, "invalid sandbox protocol frame")
        end

      _ when byte_size(state.buffer) > @max_frame_bytes ->
        finish(state, :error, "sandbox protocol frame exceeds 1 MiB")

      _ ->
        state
    end
  end

  defp consume_frame(state, %{"type" => "output", "text" => text}) when is_binary(text),
    do: state |> append(text) |> consume()

  defp consume_frame(%{detached: true} = state, %{"type" => "tool_call"} = frame) do
    if length(state.pending_calls) < 1_000,
      do: consume(%{state | pending_calls: [frame | state.pending_calls]}),
      else: finish(state, :error, "a cell may make at most 1000 tool calls")
  end

  defp consume_frame(state, %{
         "type" => "tool_call",
         "call" => call,
         "tool" => tool,
         "args" => args
       })
       when is_integer(call) and call > 0 and is_binary(tool) do
    state
    |> Map.put(:bridge, Bridge.request(state.bridge, call, tool, args))
    |> consume()
  end

  defp consume_frame(state, %{"type" => "done", "status" => "ok"} = frame),
    do: finish(state, :ok, Jason.encode!(frame["value"]))

  defp consume_frame(state, %{"type" => "done", "status" => "error", "error" => error})
       when is_binary(error),
       do: finish(state, :error, error)

  defp consume_frame(state, _frame), do: finish(state, :error, "invalid sandbox protocol frame")

  defp finish(%{status: :running} = state, status, text) do
    cleanup(state)
    state = append(state, text)
    state = %{state | status: status, port: nil, os_pid: nil, group: nil, bridge: nil, buffer: ""}

    Enum.each(state.waiters, fn {_token, {from, timer, signal}} ->
      cancel_timer(timer)
      AbortSignal.unsubscribe(signal)
      GenServer.reply(from, snapshot(state))
    end)

    arm_idle(%{state | waiters: %{}})
  end

  defp finish(state, _status, _text), do: state

  defp cleanup(state) do
    cancel_timer(state.deadline)
    cancel_timer(state.idle)
    AbortSignal.unsubscribe(state.signal)
    if state.bridge, do: Bridge.shutdown(state.bridge)
    if state.group, do: LemonCore.ProcessGroup.terminate(state.group, signal: :sigkill)
    close_port(state.port)
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp close_port(_port), do: :ok

  defp append(state, text) do
    text = String.replace_invalid(text)
    output = state.output <> text
    size = byte_size(output)
    kept = min(size, @max_output_bytes)
    output = output |> binary_part(size - kept, kept) |> String.replace_invalid("")
    %{state | output: output, truncated: state.truncated or size > kept}
  end

  defp snapshot(state) do
    %{
      cell_id: state.cell_id,
      status: if(state.status == :running, do: :yielded, else: state.status),
      output: state.output,
      truncated: state.truncated
    }
  end

  defp arm_idle(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:idle, token}, @idle_timeout_ms)
    %{state | idle: {token, timer}}
  end

  defp cancel_timer({_token, timer}), do: Process.cancel_timer(timer)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp owner_reply(operation, owner, state) do
    case CodingAgent.ToolResources.owner_reply(operation, owner, state) do
      {:reply, :ok, updated} when operation == :detach_owner ->
        {:reply, :ok, %{updated | detached: true}}

      reply ->
        reply
    end
  end

  defp resume_calls(%{bridge: nil} = state, _resolver), do: state

  defp resume_calls(%{bridge: %Bridge{} = bridge} = state, resolver) do
    bridge = if is_function(resolver, 1), do: %{bridge | resolver: resolver}, else: bridge
    pending = Enum.reverse(state.pending_calls)
    state = %{state | bridge: bridge, detached: false, pending_calls: []}

    Enum.reduce(pending, state, fn frame, acc ->
      %{acc | bridge: Bridge.request(acc.bridge, frame["call"], frame["tool"], frame["args"])}
    end)
  end
end
