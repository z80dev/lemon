defmodule CodingAgent.PythonRepl.Session do
  @moduledoc """
  One persistent Python kernel worker: a temporary GenServer that owns
  exactly one interpreter process and serializes cells against it.

  The worker keeps the protocol state machine, a bounded FIFO queue (one
  active cell; `max_queued_cells` waiting), caller monitors, and the
  startup/active timers. Its safety contract, per the persistent Python REPL
  plan:

    * **Serialization** - one active cell per worker. Active-cell timeout
      starts when the cell is dispatched (written) to the runner, never
      while queued. The runner's `started` acknowledgement confirms
      protocol state but is never required for timer safety: an untrusted
      runner cannot bypass the bound by suppressing or delaying it.
    * **Exactly-once replies** - every caller is replied to exactly once,
      whatever race ends the cell (completion, timeout, caller death,
      protocol fault, port death, shutdown).
    * **No replay** - once a cell is dispatched (and especially once
      `started` arrives) its code is never re-sent to any interpreter. Any
      failure after dispatch destroys the interpreter.
    * **State retention** - ordinary exceptions (including `SystemExit` and
      unsupported-input errors) reply `state_retained: true` and keep the
      worker. Active timeout, active caller death, protocol faults, fatal
      frames, and port death mark the namespace unsafe: partial output is
      returned, the interpreter is discarded, and the worker stops. No
      automatic retry exists at this layer.
    * **Cancellation** - SIGINT to the process group, then the shutdown
      request, with bounded INT grace before TERM/KILL tree termination.
    * **Cleanup** - `terminate/2` always terminates the process tree, closes
      the port, and removes the workspace.

  Cancellation semantics for queued callers: the death of a *queued* caller
  removes only its own request and never disturbs the active cell. The death
  of the *active* caller discards the interpreter (its namespace was mutated
  by code whose result can no longer be delivered) and stops the worker.

  Process, protocol, and output modules are injectable (`:process_mod`,
  `:protocol_mod`, `:output_mod`) so tests can drive the state machine with
  fakes; defaults are the real `CodingAgent.PythonRepl.Process`,
  `CodingAgent.PythonRepl.Protocol`, and `CodingAgent.PythonRepl.Output`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias CodingAgent.PrivateTmp
  alias CodingAgent.PythonRepl.Process, as: KernelProcess
  alias CodingAgent.PythonRepl.Telemetry

  @default_process_mod KernelProcess
  @default_protocol_mod CodingAgent.PythonRepl.Protocol
  @default_output_mod CodingAgent.PythonRepl.Output

  # Tested internal constants, deliberately non-configurable (plan).
  @default_startup_timeout_ms 10_000
  @default_bye_timeout_ms 1_000
  @default_interrupt_grace_ms 1_000
  @default_term_grace_ms 1_000
  @default_kill_grace_ms 1_000
  @default_max_queued_cells 8
  @default_max_output_bytes 50_000

  defstruct [
    :key,
    :generation,
    :cwd,
    :workspace,
    :process,
    :protocol,
    :phase,
    :startup_timer,
    :bye_timer,
    :cancel_grace_timer,
    :queue,
    :active,
    :next_id,
    :completed_cells,
    :mods,
    :limits
  ]

  defmodule Queued do
    @moduledoc false
    defstruct [:from, :caller, :monitor, :request, :timeout]
  end

  defmodule Active do
    @moduledoc false
    defstruct [
      :id,
      :from,
      :caller,
      :monitor,
      :request,
      :timeout,
      :timeout_timer,
      :dispatched_at,
      :started_at,
      :started?,
      :exception,
      :output,
      :replied?,
      :telemetry_stopped?,
      :cancel_telemetry_emitted?
    ]
  end

  @type phase :: :starting | :idle | :running | :cancelling | :stopping

  @type bridge :: %{dir: String.t(), token: String.t()}

  @type request :: %{
          required(:code) => String.t(),
          optional(:cwd) => String.t(),
          optional(:bridge) => bridge()
        }

  @type exception_info :: %{
          kind: :error | :system_exit | :unsupported_input | :interrupted | nil,
          name: String.t() | nil,
          message: String.t() | nil,
          traceback: String.t() | nil
        }

  @type result :: %{
          required(:request_id) => String.t() | nil,
          required(:state_retained) => boolean(),
          required(:duration_ms) => non_neg_integer(),
          optional(:cells_completed) => non_neg_integer(),
          optional(:reason) => atom(),
          optional(:exit_status) => integer() | nil,
          optional(:exception) => exception_info(),
          optional(:output) => String.t(),
          optional(:truncated) => boolean(),
          optional(:total_bytes) => non_neg_integer(),
          optional(:stdout_bytes) => non_neg_integer(),
          optional(:stderr_bytes) => non_neg_integer(),
          optional(:full_output_path) => String.t() | nil
        }

  @type error :: %{
          required(:reason) => atom(),
          required(:state_retained) => boolean(),
          optional(any()) => any()
        }

  @typep limits :: %{
           startup_ms: pos_integer(),
           bye_ms: pos_integer(),
           interrupt_grace_ms: non_neg_integer(),
           term_grace_ms: non_neg_integer(),
           kill_grace_ms: non_neg_integer(),
           max_queued_cells: non_neg_integer(),
           max_output_bytes: pos_integer()
         }

  @type t :: %__MODULE__{
          key: term(),
          generation: pos_integer(),
          cwd: String.t(),
          workspace: String.t() | nil,
          process: term(),
          protocol: term(),
          phase: phase(),
          startup_timer: reference() | nil,
          bye_timer: reference() | nil,
          cancel_grace_timer: reference() | nil,
          queue: :queue.queue(Queued.t()),
          active: Active.t() | nil,
          next_id: pos_integer(),
          completed_cells: non_neg_integer(),
          mods: %{process: module(), protocol: module(), output: module()},
          limits: limits()
        }

  ## Client API

  @doc """
  Starts one kernel worker.

  ## Options

    * `:key` (required) - opaque canonical key identifying this kernel
    * `:cwd` (required) - canonical working directory restored per cell
    * `:interpreter` (required) - absolute interpreter path
    * `:generation` - registry generation for this kernel (default `1`)
    * `:runner_path` - source runner script staged into the workspace
      (default: `priv/python_repl/runner.py` of `:coding_agent`)
    * `:helper_source` - optional authority-free `lemon_tools.py` source staged
      beside the runner with owner-only permissions
    * `:startup_timeout_ms`, `:bye_timeout_ms`, `:interrupt_grace_ms`,
      `:term_grace_ms`, `:kill_grace_ms`, `:max_queued_cells`,
      `:max_output_bytes` - bounds (tested defaults above)
    * `:process_mod`, `:protocol_mod`, `:output_mod` - injectable boundary
      modules for tests
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Executes one cell against the kernel, queueing behind any active cell.

  `timeout` bounds active cell time measured from dispatch to the runner;
  queue wait is not counted. The runner's `started` acknowledgement is not
  required for the bound: suppressing it cannot extend the cell's lifetime.
  The caller is monitored: death
  of a queued caller drops only its request; death of the active caller
  discards the interpreter.
  """
  @spec execute(GenServer.server(), request(), timeout()) :: {:ok, result()} | {:error, error()}
  def execute(pid, request, timeout) when is_pid(pid) do
    GenServer.call(pid, {:execute, request, timeout}, :infinity)
  end

  @doc """
  Stops the worker and synchronously cleans up the interpreter tree, port,
  and workspace. Outstanding callers are replied to exactly once.
  """
  @spec shutdown(GenServer.server(), timeout()) :: :ok
  def shutdown(pid, timeout \\ 15_000) do
    GenServer.stop(pid, :shutdown, timeout)
  end

  @doc """
  Returns redacted worker status: phase, queue depth, active request id,
  completed cell count, generation, key, and process liveness. Never includes
  code, output, or credentials.
  """
  @spec status(GenServer.server()) :: map()
  def status(pid) when is_pid(pid) do
    GenServer.call(pid, :status)
  end

  ## Initialization

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    key = Keyword.fetch!(opts, :key)
    cwd = Keyword.fetch!(opts, :cwd)
    interpreter = Keyword.fetch!(opts, :interpreter)

    unless is_binary(cwd) and cwd != "" do
      raise ArgumentError, ":cwd must be a non-empty binary"
    end

    unless is_binary(interpreter) and interpreter != "" do
      raise ArgumentError, ":interpreter must be a non-empty binary"
    end

    state = %__MODULE__{
      key: key,
      generation: Keyword.get(opts, :generation, 1),
      cwd: cwd,
      queue: :queue.new(),
      next_id: 1,
      completed_cells: 0,
      phase: :starting,
      mods: %{
        process: Keyword.get(opts, :process_mod, @default_process_mod),
        protocol: Keyword.get(opts, :protocol_mod, @default_protocol_mod),
        output: Keyword.get(opts, :output_mod, @default_output_mod)
      },
      limits: %{
        startup_ms: Keyword.get(opts, :startup_timeout_ms, @default_startup_timeout_ms),
        bye_ms: Keyword.get(opts, :bye_timeout_ms, @default_bye_timeout_ms),
        interrupt_grace_ms: Keyword.get(opts, :interrupt_grace_ms, @default_interrupt_grace_ms),
        term_grace_ms: Keyword.get(opts, :term_grace_ms, @default_term_grace_ms),
        kill_grace_ms: Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms),
        max_queued_cells: Keyword.get(opts, :max_queued_cells, @default_max_queued_cells),
        max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
      }
    }

    runner_source = Keyword.get(opts, :runner_path) || default_runner_source()
    helper_source = Keyword.fetch(opts, :helper_source)

    case boot(state, runner_source, helper_source, interpreter) do
      {:ok, ctx} ->
        startup_timer = Process.send_after(self(), :startup_timeout, state.limits.startup_ms)

        {:ok,
         %{
           state
           | workspace: ctx.workspace,
             process: ctx.process,
             protocol: ctx.protocol,
             startup_timer: startup_timer
         }}

      {:error, ctx} ->
        abort_boot(state, ctx)
        {:stop, {:shutdown, {:startup_failed, ctx[:reason]}}}
    end
  end

  # Boot walks a context map so any failure knows exactly which resources
  # exist and must be destroyed.
  defp boot(state, runner_source, helper_source, interpreter) do
    process_mod = state.mods.process

    steps = [
      fn ctx ->
        case create_workspace() do
          {:ok, dir} -> {:ok, Map.put(ctx, :workspace, dir)}
          {:error, reason} -> {:error, Map.put(ctx, :reason, {:workspace_failed, reason})}
        end
      end,
      fn ctx ->
        case stage_runner(runner_source, ctx.workspace) do
          {:ok, dest} -> {:ok, Map.put(ctx, :runner_dest, dest)}
          {:error, reason} -> {:error, Map.put(ctx, :reason, {:runner_stage_failed, reason})}
        end
      end,
      fn ctx ->
        case stage_helper_module(helper_source, ctx.workspace) do
          {:ok, dest} -> {:ok, Map.put(ctx, :helper_dest, dest)}
          {:error, reason} -> {:error, Map.put(ctx, :reason, {:helper_stage_failed, reason})}
        end
      end,
      fn ctx ->
        case process_mod.start(
               program: interpreter,
               args: ["-u", ctx.runner_dest],
               cwd: ctx.workspace,
               env: [],
               term_grace_ms: state.limits.term_grace_ms,
               kill_grace_ms: state.limits.kill_grace_ms
             ) do
          {:ok, process} -> {:ok, Map.put(ctx, :process, process)}
          {:error, reason} -> {:error, Map.put(ctx, :reason, reason)}
        end
      end,
      fn ctx ->
        case state.mods.protocol.new() do
          {:ok, protocol, []} -> {:ok, Map.put(ctx, :protocol, protocol)}
          {:ok, _protocol, _frames} -> {:error, Map.put(ctx, :reason, :unexpected_frames)}
          {:error, reason} -> {:error, Map.put(ctx, :reason, reason)}
        end
      end,
      fn ctx ->
        case send_request(process_mod, ctx.process, init_request(state.cwd)) do
          :ok -> {:ok, ctx}
          {:error, reason} -> {:error, Map.put(ctx, :reason, reason)}
        end
      end
    ]

    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, ctx} ->
      case step.(ctx) do
        {:ok, ctx} -> {:cont, {:ok, ctx}}
        {:error, ctx} -> {:halt, {:error, ctx}}
      end
    end)
  end

  defp abort_boot(state, ctx) do
    if process = ctx[:process] do
      state.mods.process.terminate_tree(process)
    end

    if workspace = ctx[:workspace] do
      remove_workspace(workspace)
    end

    :ok
  end

  defp default_runner_source do
    case :code.priv_dir(:coding_agent) do
      priv when is_list(priv) -> Path.join(priv, "python_repl/runner.py")
      _ -> "priv/python_repl/runner.py"
    end
  end

  ## Call handling

  @impl true
  def handle_call({:execute, request, timeout}, from, state) do
    caller = elem(from, 0)

    case validate_request(request, timeout) do
      :ok ->
        cond do
          state.phase in [:stopping, :cancelling] ->
            {:reply, {:error, %{reason: :shutting_down, state_retained: false}}, state}

          :queue.len(state.queue) >= state.limits.max_queued_cells ->
            {:reply, {:error, %{reason: :queue_full, state_retained: true}}, state}

          state.phase == :idle ->
            {:noreply, dispatch_cell(state, from, caller, request, timeout)}

          true ->
            {:noreply, enqueue_cell(state, from, caller, request, timeout)}
        end

      {:error, reason} ->
        {:reply, {:error, %{reason: reason, state_retained: true}}, state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      phase: state.phase,
      generation: state.generation,
      key: state.key,
      queue_depth: :queue.len(state.queue),
      active_request_id: state.active && state.active.id,
      cells_completed: state.completed_cells,
      process_alive: state.process != nil and state.mods.process.alive?(state.process)
    }

    {:reply, status, state}
  end

  ## Request validation, dispatch, queueing

  defp validate_request(request, timeout) do
    cond do
      not is_map(request) or not is_map_key(request, :code) ->
        {:error, :invalid_request}

      not is_binary(request.code) or request.code == "" ->
        {:error, :invalid_request}

      request[:cwd] != nil and (not is_binary(request.cwd) or request.cwd == "") ->
        {:error, :invalid_request}

      request[:bridge] != nil and not valid_bridge?(request.bridge) ->
        {:error, :invalid_request}

      timeout != :infinity and not (is_integer(timeout) and timeout > 0) ->
        {:error, :invalid_timeout}

      true ->
        :ok
    end
  end

  defp valid_bridge?(%{dir: dir, token: token})
       when is_binary(dir) and dir != "" and is_binary(token) and token != "",
       do: true

  defp valid_bridge?(_), do: false

  defp enqueue_cell(state, from, caller, request, timeout) do
    monitor = Process.monitor(caller)

    entry =
      struct(Queued,
        from: from,
        caller: caller,
        monitor: monitor,
        request: request,
        timeout: timeout
      )

    %{state | queue: :queue.in(entry, state.queue)}
  end

  defp dispatch_cell(state, from, caller, request, timeout, monitor \\ nil) do
    monitor = monitor || Process.monitor(caller)

    id = "cell-#{state.next_id}"
    cwd = request[:cwd] || state.cwd

    active =
      struct(
        Active,
        id: id,
        from: from,
        caller: caller,
        monitor: monitor,
        request: request,
        timeout: timeout,
        timeout_timer: nil,
        dispatched_at: monotonic_ms(),
        started_at: nil,
        started?: false,
        exception: nil,
        output: state.mods.output.new(state.limits.max_output_bytes),
        replied?: false,
        telemetry_stopped?: false,
        cancel_telemetry_emitted?: false
      )

    # The active-cell timeout is armed at dispatch, before the request is
    # written, and is never re-armed later. The runner's `started`
    # acknowledgement only confirms protocol state; an untrusted runner that
    # suppresses or delays `started` cannot bypass the bound, and even a
    # failed write terminates within the timeout.
    active = %{active | timeout_timer: arm_cell_timer(active)}

    send_request(
      state.mods.process,
      state.process,
      eval_request(id, request.code, cwd, request[:bridge])
    )

    Telemetry.cell_started(:queue.len(state.queue), state.limits.max_queued_cells)

    %{state | active: active, next_id: state.next_id + 1, phase: :running}
  end

  defp dequeue_next(%{phase: :idle} = state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, entry}, rest} ->
        state
        |> Map.put(:queue, rest)
        |> dispatch_cell(entry.from, entry.caller, entry.request, entry.timeout, entry.monitor)
    end
  end

  defp dequeue_next(state), do: state

  ## Port and protocol traffic

  @impl true
  def handle_info({source, {:data, data}}, state) do
    if state.process != nil and state.mods.process.port(state.process) == source do
      case state.mods.protocol.feed(state.protocol, data) do
        {:ok, protocol, frames} ->
          handle_frames(frames, %{state | protocol: protocol})

        {:error, reason} ->
          protocol_fault(state, reason)
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({source, {:exit_status, status}}, state) do
    if state.process != nil and state.mods.process.port(state.process) == source do
      port_exit(state, status)
    else
      {:noreply, state}
    end
  end

  # trap_exit makes a dying port deliver an EXIT as well; treat it like an
  # unsolicited exit unless we are already stopping.
  def handle_info({:EXIT, source, _reason}, state) do
    if state.process != nil and state.mods.process.port(state.process) === source and
         state.phase != :stopping do
      port_exit(state, nil)
    else
      {:noreply, state}
    end
  end

  def handle_info(:startup_timeout, %{phase: :starting} = state) do
    state =
      state
      |> fail_queued(:startup_failed)
      |> hard_teardown()

    {:stop, {:shutdown, :startup_timeout}, state}
  end

  def handle_info(:startup_timeout, state), do: {:noreply, state}

  def handle_info({:cell_timeout, id}, %{phase: :running, active: %{id: id}} = state) do
    active = %{state.active | timeout_timer: nil}

    state
    |> Map.put(:active, active)
    |> fail_active(timeout_result(state, state.active))
    |> begin_cancellation(:timeout)
  end

  def handle_info({:cell_timeout, _id}, state), do: {:noreply, state}

  def handle_info({:cancel_grace, id}, %{phase: :cancelling, active: %{id: id}} = state) do
    Logger.warning("PythonRepl.Session: interrupt grace expired; terminating interpreter tree")

    state =
      state
      |> Map.put(:cancel_grace_timer, nil)
      |> hard_teardown()

    {:stop, {:shutdown, :interrupt_grace_expired}, state}
  end

  def handle_info({:cancel_grace, _id}, state), do: {:noreply, state}

  def handle_info(:bye_timeout, %{phase: :stopping} = state) do
    state = hard_teardown(state)
    {:stop, {:shutdown, :bye_timeout}, state}
  end

  def handle_info(:bye_timeout, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      state.active != nil and state.active.monitor == ref and not state.active.replied? ->
        Logger.debug("PythonRepl.Session: active caller died; discarding interpreter")

        state
        |> Map.put(:active, %{state.active | replied?: true})
        |> emit_cell_stopped(:interrupted)
        |> begin_cancellation(:caller_exit)

      find_queued(state.queue, ref) != nil ->
        # A dead queued caller removes only its own request.
        {:noreply, %{state | queue: :queue.filter(fn e -> e.monitor != ref end, state.queue)}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Frame routing

  defp handle_frames(frames, state) do
    frames
    |> Enum.reduce_while(state, fn frame, acc ->
      case handle_frame(frame, acc) do
        {:noreply, new_state} -> {:cont, new_state}
        {:stop, reason, new_state} -> {:halt, {:stop, reason, new_state}}
      end
    end)
    |> case do
      {:stop, _, _} = stop -> stop
      state -> {:noreply, state}
    end
  end

  # ready: interpreter is up. Dispatch queued cells in FIFO order.
  defp handle_frame(%{type: :ready}, %{phase: :starting} = state) do
    state =
      state
      |> cancel_timer(:startup_timer)
      |> Map.put(:phase, :idle)

    {:noreply, dequeue_next(state)}
  end

  # started: the no-retry boundary. Confirms protocol state only; the
  # active-cell timer was armed at dispatch and is never re-armed here, so
  # no double timer can exist.
  defp handle_frame(%{type: :started, id: id}, %{phase: :running, active: active} = state)
       when active != nil and active.id == id and active.started? == false do
    active = %{active | started?: true, started_at: monotonic_ms()}

    {:noreply, %{state | active: active}}
  end

  defp handle_frame(
         %{type: :stream, id: id, stream: stream, data: data},
         %{phase: :running, active: %{id: active_id} = active} = state
       )
       when stream in [:stdout, :stderr] and active_id == id do
    active = %{active | output: state.mods.output.append(active.output, stream, data)}
    {:noreply, %{state | active: active}}
  end

  # Timeout snapshots finish the active capture before cancellation begins.
  # A late stream would append to its closed spill device, while exception
  # and done frames must still reach their clauses below to quiesce cleanly.
  defp handle_frame(
         %{type: :stream, id: id, stream: stream},
         %{phase: :cancelling, active: %{id: active_id}} = state
       )
       when stream in [:stdout, :stderr] and active_id == id,
       do: {:noreply, state}

  defp handle_frame(%{type: :stream, id: id, stream: stream}, state)
       when stream in [:stdout, :stderr] do
    protocol_fault(state, {:unexpected_stream, id})
  end

  # exception is pre-terminal information; done closes the cell. Repeats
  # within a cell are tolerated (last one wins).
  defp handle_frame(%{type: :exception, id: id} = frame, state) do
    case state do
      %{phase: phase, active: %{id: ^id} = active} when phase in [:running, :cancelling] ->
        active = %{active | exception: exception_info(frame)}
        {:noreply, %{state | active: active}}

      _ ->
        protocol_fault(state, {:unexpected_exception, id})
    end
  end

  defp handle_frame(%{type: :done, id: id}, %{phase: :running, active: %{id: id}} = state) do
    complete_cell(state)
  end

  defp handle_frame(%{type: :done, id: id}, %{phase: :cancelling, active: %{id: id}} = state) do
    # The interrupted cell quiesced. The namespace is already judged unsafe;
    # stop the interpreter through the clean bye path.
    state
    |> cancel_timer(:cancel_grace_timer)
    |> Map.put(:phase, :stopping)
    |> request_bye()
  end

  defp handle_frame(%{type: :fatal} = frame, state) do
    protocol_fault(state, {:fatal, frame[:reason]})
  end

  defp handle_frame(%{type: :bye}, %{phase: :stopping} = state) do
    state =
      state
      |> cancel_timer(:bye_timer)
      |> hard_teardown()

    {:stop, {:shutdown, :bye}, state}
  end

  defp handle_frame(frame, state) do
    protocol_fault(state, {:unexpected_frame, frame[:type]})
  end

  ## Cell completion

  defp complete_cell(%{active: active} = state) do
    state = cancel_active_timers(state)
    finished = output_info(state, active)

    {outcome, result} =
      if active.exception do
        {:exception,
         {:error,
          %{
            request_id: active.id,
            reason: :exception,
            state_retained: true,
            exception: active.exception,
            duration_ms: duration_ms(active)
          }
          |> Map.merge(finished)}}
      else
        {:ok,
         {:ok,
          %{
            request_id: active.id,
            state_retained: true,
            duration_ms: duration_ms(active),
            cells_completed: state.completed_cells + 1
          }
          |> Map.merge(finished)}}
      end

    state = emit_cell_stopped(state, outcome)
    GenServer.reply(active.from, result)

    state
    |> release_active()
    |> Map.put(:completed_cells, state.completed_cells + 1)
    |> Map.put(:phase, :idle)
    |> dequeue_next()
    |> then(&{:noreply, &1})
  end

  defp release_active(state) do
    if active = state.active do
      if active.monitor, do: Process.demonitor(active.monitor, [:flush])
      %{state | active: nil}
    else
      state
    end
  end

  ## Failure paths

  defp timeout_result(state, active) do
    {:error,
     %{
       request_id: active.id,
       reason: :timeout,
       state_retained: false,
       duration_ms: duration_ms(active)
     }
     |> Map.merge(output_info(state, active))}
  end

  defp active_error_result(state, reason) do
    {:error,
     %{
       request_id: state.active && state.active.id,
       reason: reason,
       state_retained: false,
       duration_ms: active_duration(state)
     }
     |> Map.merge(active_output_info(state))}
  end

  # Marks the namespace unsafe: replies the active caller (already done for
  # timeouts), fails every queued caller, interrupts, and arms the INT grace.
  defp begin_cancellation(state, cause) do
    state =
      state
      |> Map.put(:phase, :cancelling)
      |> emit_cell_cancelled(cause)
      |> fail_queued(:kernel_discarded)

    if state.process == nil do
      {:noreply, state}
    else
      case state.mods.process.interrupt(state.process) do
        :ok ->
          id = state.active && state.active.id

          timer =
            Process.send_after(self(), {:cancel_grace, id}, state.limits.interrupt_grace_ms)

          {:noreply, %{state | cancel_grace_timer: timer}}

        {:error, :unsupported} ->
          # No reliable soft interrupt: straight to tree termination.
          state = hard_teardown(state)
          {:stop, {:shutdown, :no_soft_interrupt}, state}
      end
    end
  end

  defp port_exit(state, status) do
    Logger.warning("PythonRepl.Session: interpreter port exited (#{inspect(status)})")

    state =
      state
      |> fail_unreplied_active(:port_exit)
      |> fail_queued(:port_exit)
      |> hard_teardown(:close)

    {:stop, {:shutdown, {:port_exit, status}}, state}
  end

  defp protocol_fault(state, detail) do
    Logger.warning(
      "PythonRepl.Session: protocol fault #{inspect(detail)}; destroying interpreter"
    )

    state =
      state
      |> fail_unreplied_active(:protocol_fault)
      |> fail_queued(:protocol_fault)
      |> hard_teardown()

    {:stop, {:shutdown, {:protocol_fault, detail}}, state}
  end

  defp fail_active(%{active: nil} = state, _result), do: state

  defp fail_active(%{active: active} = state, result) do
    if active.replied? do
      state
    else
      state = emit_cell_stopped(state, cell_outcome(result))
      active = state.active
      GenServer.reply(active.from, result)
      %{state | active: %{active | replied?: true}}
    end
  end

  # Captures are finalized before a timeout reply. Do not build a second error
  # result for an already-replied active cell: `finish/1` may otherwise flush
  # stale pending data into its closed spill device.
  defp fail_unreplied_active(%{active: %{replied?: false}} = state, reason) do
    fail_active(state, active_error_result(state, reason))
  end

  defp fail_unreplied_active(state, _reason), do: state

  defp fail_queued(state, reason) do
    entries = :queue.to_list(state.queue)

    Enum.each(entries, fn entry ->
      Process.demonitor(entry.monitor, [:flush])

      GenServer.reply(entry.from, {:error, %{reason: reason, state_retained: false}})
    end)

    %{state | queue: :queue.new()}
  end

  ## Shutdown and cleanup

  defp request_bye(state) do
    cond do
      state.process == nil or state.phase == :starting ->
        # Never became ready: the interpreter is untrusted; hard teardown.
        state |> hard_teardown() |> stop_after_teardown(:bye)

      true ->
        send_request(state.mods.process, state.process, shutdown_request())
        timer = Process.send_after(self(), :bye_timeout, state.limits.bye_ms)
        {:noreply, %{state | bye_timer: timer}}
    end
  end

  defp stop_after_teardown(state, reason) do
    {:stop, {:shutdown, reason}, state}
  end

  # Idempotent: cancels timers and removes the workspace. Confirmed-dead
  # port-exit paths use :close so they only close the port; every path where
  # the interpreter may still be alive terminates its tree.
  defp hard_teardown(state, mode \\ :terminate)

  defp hard_teardown(state, mode) when mode in [:terminate, :close] do
    state = cancel_all_timers(state)

    if state.process != nil do
      case mode do
        :terminate -> state.mods.process.terminate_tree(state.process)
        :close -> state.mods.process.close(state.process)
      end
    end

    remove_workspace(state.workspace)
    %{state | process: nil, workspace: nil}
  end

  @impl true
  def terminate(_reason, state) do
    # Exactly-once, idempotent cleanup for every exit path.
    state = cancel_all_timers(state)

    state =
      if state.active != nil and state.phase in [:running, :cancelling] do
        emit_cell_cancelled(state, :shutdown)
      else
        state
      end

    state =
      if state.active != nil and not state.active.replied? do
        fail_active(state, active_error_result(state, :interrupted))
      else
        state
      end

    state = fail_queued(state, :shutting_down)

    if state.process != nil do
      if state.active != nil and state.phase in [:running, :cancelling] do
        state.mods.process.interrupt(state.process)
        await_terminal_frame(state)
      end

      if state.phase != :starting and state.mods.process.alive?(state.process) do
        send_request(state.mods.process, state.process, shutdown_request())
        await_bye(state)
      end

      state.mods.process.terminate_tree(state.process)
    end

    remove_workspace(state.workspace)
    :ok
  end

  defp await_terminal_frame(state) do
    deadline = monotonic_ms() + state.limits.interrupt_grace_ms
    await_port_frame(state, deadline, &match?(%{type: t} when t in [:done, :exception, :bye], &1))
  end

  defp await_bye(state) do
    deadline = monotonic_ms() + state.limits.bye_ms
    await_port_frame(state, deadline, &match?(%{type: :bye}, &1))
  end

  defp await_port_frame(state, deadline, predicate) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      false
    else
      port = state.mods.process.port(state.process)

      receive do
        {^port, {:data, data}} ->
          case state.mods.protocol.feed(state.protocol, data) do
            {:ok, _protocol, frames} -> Enum.any?(frames, predicate)
            {:error, _reason} -> false
          end

        {^port, {:exit_status, _status}} ->
          true
      after
        min(remaining, 50) ->
          await_port_frame(state, deadline, predicate)
      end
    end
  end

  ## Helpers

  defp find_queued(queue, ref) do
    Enum.find(:queue.to_list(queue), &(&1.monitor == ref))
  end

  defp arm_cell_timer(%Active{timeout: :infinity}), do: nil

  defp arm_cell_timer(%Active{timeout: timeout, id: id}) do
    Process.send_after(self(), {:cell_timeout, id}, timeout)
  end

  defp cancel_timer(state, key) do
    case Map.get(state, key) do
      nil ->
        state

      timer ->
        Process.cancel_timer(timer)
        Map.put(state, key, nil)
    end
  end

  defp cancel_active_timers(state) do
    if active = state.active do
      if active.timeout_timer, do: Process.cancel_timer(active.timeout_timer)
      %{state | active: %{active | timeout_timer: nil}}
    else
      state
    end
  end

  defp cancel_all_timers(state) do
    state
    |> cancel_timer(:startup_timer)
    |> cancel_timer(:bye_timer)
    |> cancel_timer(:cancel_grace_timer)
    |> cancel_active_timers()
  end

  defp output_info(state, active) do
    finished = state.mods.output.finish(active.output)

    %{
      output: finished.output,
      truncated: finished.truncated,
      total_bytes: finished.total_bytes,
      stdout_bytes: finished.stdout_bytes,
      stderr_bytes: finished.stderr_bytes,
      full_output_path: finished.full_output_path
    }
  end

  defp active_output_info(%{active: nil}), do: %{output: "", truncated: false}

  defp active_output_info(state), do: output_info(state, state.active)

  defp active_duration(%{active: nil}), do: 0
  defp active_duration(%{active: active}), do: duration_ms(active)

  defp duration_ms(active) do
    from = active.started_at || active.dispatched_at
    max(monotonic_ms() - from, 0)
  end

  defp emit_cell_stopped(%{active: nil} = state, _outcome), do: state

  defp emit_cell_stopped(%{active: %{telemetry_stopped?: true}} = state, _outcome), do: state

  defp emit_cell_stopped(%{active: active} = state, outcome) do
    Telemetry.cell_stopped(duration_ms(active), outcome)
    %{state | active: %{active | telemetry_stopped?: true}}
  end

  defp emit_cell_cancelled(%{active: nil} = state, _cause), do: state

  defp emit_cell_cancelled(%{active: %{cancel_telemetry_emitted?: true}} = state, _cause),
    do: state

  defp emit_cell_cancelled(%{active: active} = state, cause) do
    Telemetry.cell_cancelled(duration_ms(active), cause)
    %{state | active: %{active | cancel_telemetry_emitted?: true}}
  end

  defp cell_outcome({_, %{reason: reason}}), do: reason
  defp cell_outcome(_result), do: :unknown

  defp exception_info(frame) do
    %{
      kind: frame[:kind],
      name: frame[:name] || frame[:exc_type],
      message: frame[:message],
      traceback: frame[:traceback]
    }
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  ## Workspace management

  # All three objects come from `PrivateTmp`: the workspace is reserved
  # atomically at 0700 and both staged files are reserved at 0600 and
  # published by rename. `File.cp/2` is deliberately not used — it copies the
  # source's mode bits onto the destination — and nothing chmods after
  # creation, so no staged object is ever observable with umask-derived
  # permissions.
  defp create_workspace do
    with {:ok, root} <- PrivateTmp.root(),
         {:ok, dir} <- PrivateTmp.reserve_dir(root, "lemon-pyrepl") do
      {:ok, dir}
    end
  end

  defp stage_runner(source, workspace) do
    case PrivateTmp.copy_file(source, workspace, "runner.py") do
      :ok -> {:ok, Path.join(workspace, "runner.py")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage_helper_module(:error, _workspace), do: {:ok, nil}

  defp stage_helper_module({:ok, source}, workspace) when is_binary(source) do
    case PrivateTmp.write_file(workspace, "lemon_tools.py", source) do
      :ok -> {:ok, Path.join(workspace, "lemon_tools.py")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage_helper_module({:ok, _source}, _workspace), do: {:error, :invalid_source}

  defp remove_workspace(nil), do: :ok

  # Bounded: cell code could have planted an arbitrarily large tree in its
  # workspace, and File.rm_rf/1 would enumerate without limit. Leftovers
  # stay owner-only under the private root for the boot-time sweep.
  defp remove_workspace(workspace) do
    case PrivateTmp.remove_tree(workspace) do
      :complete ->
        :ok

      :truncated ->
        Logger.warning(
          "PythonRepl.Session: workspace teardown hit the entry limit; " <>
            "remainder left under the private root"
        )

        :ok
    end
  end

  ## Wire encoding (parent -> child NDJSON requests)

  defp send_request(_mod, nil, _request), do: {:error, :no_process}

  defp send_request(mod, process, request) do
    data = [Jason.encode!(request), ?\n]

    try do
      mod.write(process, data)
      :ok
    rescue
      _ -> {:error, :closed}
    catch
      _, _ -> {:error, :closed}
    end
  end

  defp init_request(cwd), do: %{"v" => 1, "type" => "init", "cwd" => cwd}

  defp eval_request(id, code, cwd, nil),
    do: %{"v" => 1, "type" => "eval", "id" => id, "code" => code, "cwd" => cwd}

  defp eval_request(id, code, cwd, bridge) do
    %{"v" => 1, "type" => "eval", "id" => id, "code" => code, "cwd" => cwd}
    |> Map.put("bridge", %{"dir" => bridge.dir, "token" => bridge.token})
  end

  defp shutdown_request, do: %{"v" => 1, "type" => "shutdown"}
end
