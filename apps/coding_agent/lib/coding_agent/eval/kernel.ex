defmodule CodingAgent.Eval.Kernel do
  @moduledoc """
  One `eval` kernel slot: a persistent Python or JavaScript process for one
  owner (coding session) and language.

  The slot GenServer owns the kernel `Port`, which runs a driver from
  `priv/eval/` (`python_kernel.py` under `python3`/`python`, `js_kernel.js`
  under `bun`/`node`) in the session cwd. Commands are newline-delimited JSON
  on stdin. The kernel's stdout and stderr are one merged stream: protocol
  frames are lines prefixed with a per-process random marker and everything
  else is user output, relayed to the caller as it arrives. User code printing
  JSON, partial lines or protocol-looking text therefore cannot desynchronise
  the protocol.

  One cell runs at a time. Kernel state is lost (and the OS process tree is
  killed) on timeout, abort, `reset`, kernel crash, idle timeout, owner exit and
  slot shutdown. The slot stays alive after a kill while its owner lives, so the
  next run reports that it started a fresh kernel and why the previous one
  ended. Without an owner pid the slot stops entirely after its idle timeout.

  Caller messages for an accepted run `ref`:

    * `{:lemon_eval, ref, {:output, binary}}` - raw user output bytes
    * `{:lemon_eval, ref, {:result, map}}` - the driver's result frame
    * `{:lemon_eval, ref, {:exited, status}}` - the kernel process exited
  """

  use GenServer

  alias CodingAgent.BashExecutor

  @default_idle_timeout_ms 30 * 60 * 1000
  @startup_timeout_ms 20_000
  @max_frame_bytes 16 * 1024 * 1024

  @type language :: String.t()
  @type lost_reason :: :timeout | :aborted | :reset | :crashed | :idle

  defstruct [
    :key,
    :language,
    :cwd,
    :runtime,
    :owner_ref,
    :owner_pid,
    :idle_timeout_ms,
    :idle_timer,
    :port,
    :os_pid,
    :marker,
    :busy,
    :lost_reason,
    buffer: "",
    generation: 0,
    next_id: 1
  ]

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc """
  Starts a slot. Options: `:key` (registry key, required), `:language`
  (`"py"` | `"js"`), `:cwd`, `:runtime` (executable path), `:owner_pid`,
  `:idle_timeout_ms` and `:name`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Runs `code`, starting a kernel first when the slot has none. With `reset:
  true` an existing kernel is killed first.

  Returns `{:ok, %{ref: ref, restarted: nil | lost_reason}}`, where `restarted`
  names why a previous kernel in this slot ended when this run had to start a
  fresh one.
  """
  @spec run(GenServer.server(), String.t(), keyword()) ::
          {:ok, %{ref: reference(), restarted: lost_reason() | nil}} | {:error, term()}
  def run(slot, code, opts \\ []) do
    GenServer.call(
      slot,
      {:run, code, Keyword.get(opts, :reset, false), self()},
      @startup_timeout_ms + 10_000
    )
  end

  @doc """
  Kills the kernel running `ref` (state is lost). Output already received from
  the kernel is relayed to the caller before this returns.
  """
  @spec interrupt(GenServer.server(), reference(), :timeout | :aborted) :: :ok
  def interrupt(slot, ref, reason) do
    GenServer.call(slot, {:interrupt, ref, reason}, 15_000)
  catch
    :exit, _ -> :ok
  end

  @doc "OS pid of the running kernel process, if any."
  @spec os_pid(GenServer.server()) :: integer() | nil
  def os_pid(slot), do: GenServer.call(slot, :os_pid)

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner_ref =
      case Keyword.get(opts, :owner_pid) do
        pid when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    state = %__MODULE__{
      key: Keyword.fetch!(opts, :key),
      language: Keyword.fetch!(opts, :language),
      cwd: Keyword.fetch!(opts, :cwd),
      runtime: Keyword.fetch!(opts, :runtime),
      owner_ref: owner_ref,
      owner_pid: Keyword.get(opts, :owner_pid),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms) || @default_idle_timeout_ms
    }

    {:ok, arm_idle(state)}
  end

  @impl true
  def handle_call({operation, owner}, _from, state)
      when operation in [:bind_owner, :detach_owner],
      do: CodingAgent.ToolResources.owner_reply(operation, owner, state)

  def handle_call({:run, _code, _reset, _caller}, _from, %{busy: busy} = state)
      when busy != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:run, code, reset, caller}, _from, state) do
    state = if reset and state.port, do: kill_kernel(state, :reset), else: state
    restarted = if state.port == nil and state.generation > 0, do: state.lost_reason || :reset

    case ensure_kernel(state) do
      {:ok, state} ->
        id = state.next_id
        Port.command(state.port, [Jason.encode!(%{op: "execute", id: id, code: code}), "\n"])
        ref = make_ref()
        busy = %{ref: ref, caller: caller, monitor: Process.monitor(caller), id: id}
        state = cancel_idle(%{state | busy: busy, next_id: id + 1})
        {:reply, {:ok, %{ref: ref, restarted: restarted}}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, arm_idle(state)}
    end
  end

  def handle_call({:interrupt, ref, reason}, _from, %{busy: %{ref: ref}} = state) do
    {:reply, :ok, state |> kill_kernel(reason) |> arm_idle()}
  end

  def handle_call({:interrupt, _ref, _reason}, _from, state), do: {:reply, :ok, state}

  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, consume(state, data)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if state.os_pid, do: BashExecutor.kill_process_tree(state.os_pid)
    state = flush_buffer(state)

    if state.busy do
      notify(state, {:exited, status})
      Process.demonitor(state.busy.monitor, [:flush])
    end

    {:noreply, arm_idle(%{state | port: nil, os_pid: nil, busy: nil, lost_reason: :crashed})}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}
  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{busy: %{monitor: ref}} = state) do
    # The caller died mid-cell; nobody can receive this cell's result.
    {:noreply, state |> kill_kernel(:aborted) |> arm_idle()}
  end

  def handle_info({:idle_timeout, timer}, %{idle_timer: timer, busy: nil} = state) do
    state = if state.port, do: kill_kernel(state, :idle), else: state

    if state.owner_ref,
      do: {:noreply, %{state | idle_timer: nil}},
      else: {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port, do: kill_kernel(state, :aborted)
    :ok
  end

  # ── Kernel process ──────────────────────────────────────────────────────

  defp ensure_kernel(%{port: port} = state) when port != nil, do: {:ok, state}

  defp ensure_kernel(state) do
    token = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    marker = "\x1eLEMONEVAL:" <> token <> ":"

    env = [
      {~c"LEMON_EVAL_TOKEN", String.to_charlist(token)},
      {~c"PYTHONUNBUFFERED", ~c"1"},
      {~c"PYTHONDONTWRITEBYTECODE", ~c"1"},
      {~c"NO_COLOR", ~c"1"}
    ]

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      :hide,
      {:args, [driver_path(state.language)]},
      {:cd, state.cwd},
      {:env, env}
    ]

    try do
      port = Port.open({:spawn_executable, state.runtime}, port_opts)
      os_pid = with {:os_pid, pid} <- Port.info(port, :os_pid), do: pid

      state = %{
        state
        | port: port,
          os_pid: os_pid,
          marker: marker,
          buffer: "",
          generation: state.generation + 1,
          lost_reason: nil
      }

      await_ready(state, System.monotonic_time(:millisecond) + @startup_timeout_ms, [])
    rescue
      error ->
        {:error, "could not start #{state.runtime}: #{Exception.message(error)}", state}
    end
  end

  defp await_ready(%{port: port} = state, deadline, startup_output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {frames, raw, buffer} = split_frames(state.buffer <> data, state.marker)
        state = %{state | buffer: buffer}
        startup_output = [startup_output | raw]

        if Enum.any?(frames, &match?(%{"type" => "ready"}, &1)),
          do: {:ok, state},
          else: await_ready(state, deadline, startup_output)

      {^port, {:exit_status, status}} ->
        output = startup_tail([startup_output, state.buffer])

        {:error, "kernel exited during startup (status #{status})#{output}",
         %{state | port: nil, os_pid: nil, buffer: "", lost_reason: :crashed}}
    after
      remaining ->
        output = startup_tail([startup_output, state.buffer])
        state = kill_kernel(state, :crashed)
        {:error, "kernel did not start within #{div(@startup_timeout_ms, 1000)}s#{output}", state}
    end
  end

  defp startup_tail(iodata) do
    case iodata |> IO.iodata_to_binary() |> BashExecutor.sanitize_output() |> String.trim() do
      "" -> ""
      text -> ":\n" <> String.slice(text, -2000, 2000)
    end
  end

  defp kill_kernel(%{port: nil} = state, _reason), do: state

  defp kill_kernel(%{port: port} = state, reason) do
    if state.os_pid, do: BashExecutor.kill_process_tree(state.os_pid)

    # Relay output that was produced before the kill.
    state = drain_port(state)
    state = flush_buffer(state)

    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end

    if state.busy, do: Process.demonitor(state.busy.monitor, [:flush])
    %{state | port: nil, os_pid: nil, busy: nil, buffer: "", lost_reason: reason}
  end

  defp drain_port(%{port: port} = state) do
    receive do
      {^port, {:data, data}} -> state |> consume(data) |> drain_port()
    after
      0 -> state
    end
  end

  defp driver_path("py"), do: Application.app_dir(:coding_agent, "priv/eval/python_kernel.py")
  defp driver_path("js"), do: Application.app_dir(:coding_agent, "priv/eval/js_kernel_host.js")

  # ── Stream parsing ──────────────────────────────────────────────────────

  defp consume(state, data) do
    {frames, raw, buffer} = split_frames(state.buffer <> data, state.marker)
    state = %{state | buffer: buffer}
    if IO.iodata_length(raw) > 0, do: notify(state, {:output, IO.iodata_to_binary(raw)})

    state =
      if byte_size(buffer) > @max_frame_bytes do
        notify(state, {:output, buffer})
        %{state | buffer: ""}
      else
        state
      end

    Enum.reduce(frames, state, &handle_frame/2)
  end

  defp flush_buffer(%{buffer: ""} = state), do: state

  defp flush_buffer(state) do
    notify(state, {:output, state.buffer})
    %{state | buffer: ""}
  end

  defp handle_frame(%{"type" => "result", "id" => id} = frame, %{busy: %{id: id}} = state) do
    notify(state, {:result, frame})
    Process.demonitor(state.busy.monitor, [:flush])
    arm_idle(%{state | busy: nil})
  end

  defp handle_frame(_frame, state), do: state

  defp notify(%{busy: %{ref: ref, caller: caller}}, message),
    do: send(caller, {:lemon_eval, ref, message})

  defp notify(_state, _message), do: :ok

  @doc false
  # Splits `data` into decoded frames, raw output iodata and a retained
  # remainder (an incomplete frame or a possible marker prefix).
  @spec split_frames(binary(), binary()) :: {[map()], iodata(), binary()}
  def split_frames(data, marker), do: split_frames(data, marker, [], [])

  defp split_frames(data, marker, frames, raw) do
    case :binary.match(data, marker) do
      {pos, len} ->
        before = binary_part(data, 0, pos)
        rest = binary_part(data, pos + len, byte_size(data) - pos - len)

        case :binary.match(rest, "\n") do
          {nl, 1} ->
            line = binary_part(rest, 0, nl)
            after_line = binary_part(rest, nl + 1, byte_size(rest) - nl - 1)

            case Jason.decode(line) do
              {:ok, %{} = frame} ->
                split_frames(after_line, marker, [frame | frames], [raw | before])

              _ ->
                # Not a well-formed frame: treat the line as user output.
                split_frames(after_line, marker, frames, [raw, before, line, "\n"])
            end

          :nomatch ->
            {Enum.reverse(frames), [raw | before], binary_part(data, pos, byte_size(data) - pos)}
        end

      :nomatch ->
        keep = partial_marker_suffix(data, marker)
        emit = binary_part(data, 0, byte_size(data) - keep)
        {Enum.reverse(frames), [raw | emit], binary_part(data, byte_size(data) - keep, keep)}
    end
  end

  # Length of the longest suffix of `data` that is a proper prefix of `marker`.
  defp partial_marker_suffix(data, marker) do
    max_len = min(byte_size(data), byte_size(marker) - 1)

    Enum.find(max_len..1//-1, 0, fn len ->
      binary_part(data, byte_size(data) - len, len) == binary_part(marker, 0, len)
    end)
  end

  # ── Idle timer ──────────────────────────────────────────────────────────

  defp arm_idle(state) do
    state = cancel_idle(state)
    timer = make_ref()
    Process.send_after(self(), {:idle_timeout, timer}, state.idle_timeout_ms)
    %{state | idle_timer: timer}
  end

  defp cancel_idle(state), do: %{state | idle_timer: nil}
end
