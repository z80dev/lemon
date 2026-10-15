defmodule LemonOmp.Session do
  @moduledoc """
  Owns one `omp --mode rpc` OS process for one Lemon invocation.

  A session is started by `LemonOmp.Manager` under `LemonOmp.SessionSupervisor`
  (`restart: :temporary`): a crashed omp is reported, never silently relaunched,
  because relaunching would replay a prompt the delegate may already have acted
  on. Each process gets a fresh invocation id; resuming an omp session starts a
  new invocation, so steering or cancelling an old id fails closed even while
  the same omp session runs under a newer one.

  ## Lifecycle and orphans

  The process is spawned through `/bin/sh -c 'exec ...'`, so the port's OS pid
  is omp itself, with stderr appended to a private temp file whose bounded tail
  is reported if omp exits abnormally. omp treats stdin EOF as a disconnect: it
  aborts the in-flight turn (including its shell children), disposes the
  session and exits. Because the port owns omp's stdin, any death of this
  process — normal stop, crash, or the whole VM — closes the pipe. `terminate/2`
  additionally escalates to SIGTERM and SIGKILL (descendants first) if omp has
  not exited within a short grace period.

  ## Steering and cancellation

  Control messages are acknowledged only after omp answers the correlated
  command with `success: true`. omp's error response becomes `{:rejected, msg}`;
  no answer within the command timeout becomes `:outcome_unknown`, which callers
  must not retry automatically — the command may already have taken effect.
  """

  use GenServer, restart: :temporary, shutdown: 5_000

  alias LemonOmp.{Approval, Config, Manager, Projection, Rpc, Worktree}

  @line_bytes 65_536
  @max_frame_bytes 4 * 1_048_576
  @publish_interval_ms 400
  # Fits, with its prefix, in the projection's 1000-char error, which keeps
  # the head of a string: a longer tail would lose its most recent lines.
  @stderr_tail_bytes 900
  @settle_fallback_ms 2_000
  @exit_grace_ms 1_500
  @max_pending_approvals 32

  @type start_opts :: [
          id: String.t(),
          executable: String.t(),
          cwd: String.t(),
          prompt: String.t() | nil,
          model: String.t() | nil,
          thinking: String.t() | nil,
          approval_mode: String.t() | nil,
          resume: String.t() | nil,
          owner: map()
        ]

  ## Client API

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Block until the initial prompt is acknowledged (or, without a prompt, until
  omp is ready). Returns the current wire snapshot or a startup error.
  """
  @spec await_started(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def await_started(pid, timeout), do: safe_call(pid, :await_started, timeout)

  @spec send_message(pid(), String.t(), :steer | :follow_up) ::
          {:ok, map()} | {:error, term()}
  def send_message(pid, message, mode),
    do: safe_call(pid, {:send_message, message, mode}, Config.command_timeout_ms() + 2_000)

  @spec cancel(pid()) :: {:ok, map()} | {:error, term()}
  def cancel(pid), do: safe_call(pid, :cancel, Config.command_timeout_ms() + 2_000)

  @spec subagent(pid(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def subagent(pid, subagent_id, limit),
    do: safe_call(pid, {:subagent, subagent_id, limit}, Config.command_timeout_ms() + 2_000)

  @spec close(pid()) :: :ok
  def close(pid) do
    ref = Process.monitor(pid)
    GenServer.cast(pid, :close)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      10_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp safe_call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :outcome_unknown}
    :exit, _reason -> {:error, :not_running}
  end

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :id)
    stderr_path = stderr_path(id)

    projection =
      Projection.new(
        id: id,
        cwd: Keyword.fetch!(opts, :cwd),
        worktree: Worktree.wire(Keyword.get(opts, :worktree)),
        model: Keyword.get(opts, :model),
        thinking: Keyword.get(opts, :thinking),
        approval_mode: Keyword.get(opts, :approval_mode),
        owner: Keyword.get(opts, :owner, %{kind: :operator}),
        prompt: Keyword.get(opts, :prompt)
      )

    state = %{
      id: id,
      projection: projection,
      worktree: Keyword.get(opts, :worktree),
      port: nil,
      os_pid: nil,
      stderr_path: stderr_path,
      buffer: [],
      buffer_bytes: 0,
      skipping: false,
      ready?: false,
      prompt: Keyword.get(opts, :prompt),
      resume: Keyword.get(opts, :resume),
      start_waiters: [],
      started: nil,
      pending: %{},
      approvals: %{},
      seq: 0,
      ready_timer: nil,
      idle_timer: nil,
      publish_timer: nil,
      last_publish: 0,
      close_reason: nil,
      malformed: 0,
      agent_starts: 0
    }

    case open_port(opts, stderr_path) do
      {:ok, port, os_pid} ->
        timer = Process.send_after(self(), :ready_timeout, Config.ready_timeout_ms())
        state = %{state | port: port, os_pid: os_pid, ready_timer: timer}
        publish(state, "started")
        {:ok, state}

      {:error, reason} ->
        {:stop, {:shutdown, {:spawn_failed, reason}}}
    end
  end

  @impl true
  def handle_call(:await_started, from, %{started: nil} = state),
    do: {:noreply, %{state | start_waiters: [from | state.start_waiters]}}

  def handle_call(:await_started, _from, %{started: result} = state),
    do: {:reply, result, state}

  def handle_call({:send_message, _message, _mode}, _from, %{ready?: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:send_message, message, mode}, from, state) do
    {type, delivery} =
      case {state.projection.status, mode} do
        {:running, :follow_up} -> {"follow_up", "followUp"}
        {:running, _steer} -> {"steer", "steer"}
        {_idle, _mode} -> {"prompt", "prompt"}
      end

    {:noreply, request(state, type, %{"message" => message}, {:send, from, delivery})}
  end

  def handle_call(:cancel, _from, %{projection: %{status: status}} = state)
      when status != :running,
      do: {:reply, {:error, :no_active_turn}, state}

  def handle_call(:cancel, from, state),
    do: {:noreply, request(state, "abort", %{}, {:cancel, from})}

  def handle_call({:subagent, _id, _limit}, _from, %{ready?: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:subagent, id, limit}, from, state) do
    {:noreply,
     request(state, "get_subagent_messages", %{"subagentId" => id}, {:subagent, from, limit})}
  end

  @impl true
  def handle_cast(:close, state), do: {:stop, :normal, %{state | close_reason: :closed}}

  @impl true
  def handle_info({port, {:data, {flag, chunk}}}, %{port: port} = state) do
    {:noreply, ingest(state, flag, chunk)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    reason = state.close_reason || if(code == 0, do: :exited, else: :crashed)
    status = if reason in [:closed, :idle_timeout, :exited], do: :closed, else: :failed
    error = if status == :failed, do: exit_error(state, code)
    state = cancel_approvals(%{state | port: nil, os_pid: nil}, "omp exited")

    # Publish the terminal snapshot before answering waiters, so a caller that
    # sees the error never reads a snapshot (or live count) still "starting".
    state =
      update_projection(
        state,
        &Projection.finish(&1, status, %{code: code, reason: reason, error: error})
      )

    publish(state, "exited")
    state = fail_waiters(state, error || "omp exited before it was ready")
    state = fail_pending(state)
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}

  def handle_info(:ready_timeout, %{ready?: false} = state) do
    state =
      mark_failed(%{state | close_reason: :startup_timeout}, "omp did not become ready in time")

    {:stop, :normal, fail_waiters(state, "omp did not become ready in time")}
  end

  def handle_info(:ready_timeout, state), do: {:noreply, state}

  def handle_info({:command_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending} ->
        {:noreply, reply_pending(%{state | pending: pending}, entry, {:error, :outcome_unknown})}
    end
  end

  def handle_info(:idle_timeout, %{projection: %{status: :idle}} = state),
    do: {:stop, :normal, %{state | close_reason: :idle_timeout}}

  def handle_info(:idle_timeout, state), do: {:noreply, %{state | idle_timer: nil}}

  # omp normally reports a turn's verdict right after `agent_end`; if it never
  # does, settle anyway so the session cannot stay "running" forever.
  def handle_info({:settle_fallback, turns}, %{projection: projection} = state) do
    if projection.status == :running and projection.settling and projection.turns == turns do
      {:noreply, handle_frame(state, {:event, "session_settled", %{}})}
    else
      {:noreply, state}
    end
  end

  def handle_info(:publish, state) do
    state = %{state | publish_timer: nil}
    publish(state, "updated")
    {:noreply, %{state | last_publish: now_ms()}}
  end

  def handle_info({:approval_result, dialog_id, approval_id, result}, state) do
    case state.approvals[dialog_id] do
      %{id: ^approval_id} ->
        {outcome, fields} = approval_reply(result)
        reply = Map.merge(%{"type" => "extension_ui_response", "id" => dialog_id}, fields)
        if state.port, do: write(state, reply)
        {:noreply, finish_approval(state, dialog_id, outcome)}

      _ ->
        # omp may have cancelled the dialog while the operator resolved it.
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) when is_pid(pid) do
    case Enum.find(state.approvals, fn {_dialog, entry} -> entry.pid == pid end) do
      {dialog_id, entry} ->
        handle_info({:approval_result, dialog_id, entry.id, {:error, :waiter_exited}}, state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = cancel_approvals(state, "omp session closed")
    if state.port, do: stop_process(state)

    worktree = Worktree.cleanup(state.worktree)
    state = update_projection(state, &%{&1 | worktree: worktree})

    state =
      if state.projection.status not in [:closed, :failed] do
        update_projection(
          state,
          &Projection.finish(&1, :closed, %{code: nil, reason: state.close_reason || :closed})
        )
      else
        state
      end

    publish(state, "exited")

    _ = File.rm(state.stderr_path)
    :ok
  end

  ## Port I/O

  defp ingest(state, :noeol, chunk) do
    cond do
      state.skipping ->
        state

      state.buffer_bytes + byte_size(chunk) > @max_frame_bytes ->
        %{state | buffer: [], buffer_bytes: 0, skipping: true, malformed: state.malformed + 1}

      true ->
        %{
          state
          | buffer: [state.buffer | chunk],
            buffer_bytes: state.buffer_bytes + byte_size(chunk)
        }
    end
  end

  defp ingest(state, :eol, chunk) do
    if state.skipping do
      %{state | skipping: false, buffer: [], buffer_bytes: 0}
    else
      line = IO.iodata_to_binary([state.buffer | chunk])
      state = %{state | buffer: [], buffer_bytes: 0}

      if String.trim(line) == "", do: state, else: handle_frame(state, Rpc.decode(line))
    end
  end

  defp handle_frame(state, {:ready, _frame}) do
    if state.ready_timer, do: Process.cancel_timer(state.ready_timer)
    state = %{state | ready?: true, ready_timer: nil}

    state =
      state
      |> request("set_subagent_subscription", %{"level" => "progress"}, :ignore)
      |> request("get_session_stats", %{}, :stats)
      |> maybe_request_state()

    case state.prompt do
      prompt when is_binary(prompt) ->
        request(state, "prompt", %{"message" => prompt}, :initial_prompt)

      _ ->
        state
        |> update_projection(&Projection.settle/1)
        |> started({:ok, nil})
        |> schedule_idle()
    end
  end

  defp handle_frame(state, {:response, id, _command, result}) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {entry, pending} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        handle_response(%{state | pending: pending}, entry, result)
    end
  end

  defp handle_frame(state, {:ui_request, _id, "cancel", %{"targetId" => target}}) do
    case state.approvals[target] do
      nil ->
        state

      entry ->
        Approval.cancel(entry.pid, entry.id, "omp cancelled approval")
        finish_approval(state, target, nil)
    end
  end

  defp handle_frame(
         state,
         {:ui_request, id, "select", %{"options" => ["Approve", "Deny"]} = frame}
       ) do
    cond do
      Map.has_key?(state.approvals, id) ->
        state

      Config.approvals() == :bridge and map_size(state.approvals) < @max_pending_approvals ->
        request_approval(state, id, frame)

      true ->
        decline_ui_request(state, id, "select")
    end
  end

  defp handle_frame(state, {:ui_request, id, method, _frame}),
    do: decline_ui_request(state, id, method)

  defp handle_frame(state, {:host_request, id, frame}) do
    write(state, Rpc.reject_host_request(id, frame))
    state
  end

  defp handle_frame(state, {:event, type, frame}) do
    before = state.projection

    state =
      if type == "agent_start", do: %{state | agent_starts: state.agent_starts + 1}, else: state

    state = update_projection(state, &Projection.apply_event(&1, type, frame))
    after_status = state.projection.status

    cond do
      before.status == :running and after_status == :idle ->
        state
        |> request("get_session_stats", %{}, :stats)
        |> schedule_idle()
        |> publish_now("settled")

      before.status != :running and after_status == :running ->
        state |> cancel_idle() |> publish_now("updated")

      state.projection.settling and not before.settling ->
        Process.send_after(
          self(),
          {:settle_fallback, state.projection.turns},
          @settle_fallback_ms
        )

        publish_now(state, "updated")

      type in ["tool_execution_start", "tool_execution_end", "subagent_lifecycle", "message_end"] ->
        publish_now(state, "updated")

      true ->
        schedule_publish(state)
    end
  end

  defp handle_frame(state, {:malformed, _reason}), do: %{state | malformed: state.malformed + 1}

  defp handle_response(state, %{kind: :initial_prompt} = entry, {:ok, data}) do
    state =
      if is_map(data) and data["agentInvoked"] == false do
        state |> update_projection(&Projection.settle/1) |> schedule_idle()
      else
        mark_running_after_ack(state, entry)
      end

    publish_now(started(state, {:ok, nil}), "updated")
  end

  defp handle_response(state, %{kind: :initial_prompt}, {:error, message, _code}) do
    state = started(state, {:error, {:rejected, Projection.clean(message, 500)}})

    state
    |> update_projection(&Projection.settle(%{&1 | error: Projection.clean(message, 1_000)}))
    |> schedule_idle()
  end

  defp handle_response(state, %{kind: {:send, from, delivery}} = entry, {:ok, _data}) do
    GenServer.reply(from, {:ok, %{"delivery" => delivery}})

    if delivery == "prompt" do
      state |> cancel_idle() |> mark_running_after_ack(entry) |> publish_now("updated")
    else
      state
    end
  end

  defp handle_response(state, %{kind: {:send, from, _delivery}}, {:error, message, _code}) do
    GenServer.reply(from, {:error, {:rejected, Projection.clean(message, 500)}})
    state
  end

  defp handle_response(state, %{kind: {:cancel, from}}, {:ok, _data}) do
    GenServer.reply(from, {:ok, %{"cancelled" => true}})
    state
  end

  defp handle_response(state, %{kind: {:cancel, from}}, {:error, message, _code}) do
    GenServer.reply(from, {:error, {:rejected, Projection.clean(message, 500)}})
    state
  end

  defp handle_response(state, %{kind: {:subagent, from, limit}}, {:ok, data}) do
    GenServer.reply(from, {:ok, Projection.subagent_transcript(data, limit)})
    state
  end

  defp handle_response(state, %{kind: {:subagent, from, _limit}}, {:error, message, _code}) do
    GenServer.reply(from, {:error, {:rejected, Projection.clean(message, 500)}})
    state
  end

  defp handle_response(state, %{kind: :stats}, {:ok, data}) when is_map(data),
    do: state |> update_projection(&Projection.apply_stats(&1, data)) |> schedule_publish()

  defp handle_response(state, %{kind: :state}, {:ok, data}) when is_map(data),
    do: state |> update_projection(&Projection.apply_state(&1, data)) |> schedule_publish()

  defp handle_response(state, _entry, _result), do: state

  defp decline_ui_request(state, id, method) do
    case Rpc.decline_ui_request(id, method) do
      nil ->
        state

      reply ->
        write(state, reply)

        update_projection(state, fn projection ->
          %{projection | declined_prompts: projection.declined_prompts + 1}
        end)
        |> schedule_publish()
    end
  end

  defp request_approval(state, dialog_id, frame) do
    approval_id = LemonCore.Id.approval_id()
    details = Projection.clean(frame["title"], 2_000)

    tool =
      case Regex.run(~r/^Allow tool:[ \t]*([^\n]+)/m, details, capture: :all_but_first) do
        [name] -> name |> String.trim() |> Projection.clean(64)
        _ -> ""
      end

    timeout =
      case frame["timeout"] do
        ms when is_integer(ms) and ms >= 0 -> min(ms, Config.approval_timeout_ms())
        _ -> Config.approval_timeout_ms()
      end

    params =
      state.projection.owner
      |> Map.take([:session_key, :session_id, :run_id, :agent_id])
      # Operators have no conversation key; bind their grants to this invocation.
      |> Map.put_new(:session_key, "omp:operator:" <> state.id)
      |> Map.merge(%{
        approval_id: approval_id,
        tool: if(tool == "", do: "omp", else: "omp:" <> tool),
        action: %{
          "type" => "omp_tool",
          "ompSession" => state.id,
          "tool" => if(tool == "", do: "omp", else: tool),
          "details" => details
        },
        rationale: Projection.clean("omp session #{state.id} in #{state.projection.cwd}", 300),
        expires_in_ms: timeout
      })

    waiter = Approval.start(self(), dialog_id, params)
    entry = %{id: approval_id, pid: waiter}

    %{state | approvals: Map.put(state.approvals, dialog_id, entry)}
    |> update_projection(
      &Projection.request_approval(&1, approval_id, params.action["tool"], details)
    )
    |> publish_now("approval_requested")
  end

  defp approval_reply({:ok, :approved, _scope}), do: {:approved, %{"value" => "Approve"}}
  defp approval_reply({:ok, :denied}), do: {:denied, %{"value" => "Deny"}}

  defp approval_reply({:error, :timeout}),
    do: {:expired, %{"cancelled" => true, "timedOut" => true}}

  defp approval_reply(_error), do: {:expired, %{"cancelled" => true}}

  defp finish_approval(state, dialog_id, outcome) do
    {entry, approvals} = Map.pop!(state.approvals, dialog_id)

    %{state | approvals: approvals}
    |> update_projection(&Projection.resolve_approval(&1, entry.id, outcome))
    |> publish_now("approval_resolved")
  end

  defp cancel_approvals(state, reason) do
    Enum.reduce(state.approvals, state, fn {dialog_id, entry}, acc ->
      Approval.cancel(entry.pid, entry.id, reason)

      %{acc | approvals: Map.delete(acc.approvals, dialog_id)}
      |> update_projection(&Projection.resolve_approval(&1, entry.id, nil))
    end)
  end

  defp mark_running(%Projection{status: status} = projection) when status in [:starting, :idle],
    do: %{projection | status: :running, activity: projection.activity || "Starting turn"}

  defp mark_running(projection), do: projection

  # omp may stream (and even finish) the turn before acknowledging the prompt.
  # If a turn started after the request went out, the events already tell the
  # truth; marking the session running again would leave nothing to settle it.
  defp mark_running_after_ack(state, %{agent_starts: seen}) when state.agent_starts > seen,
    do: state

  defp mark_running_after_ack(state, _entry), do: update_projection(state, &mark_running/1)

  # A resumed session carries todos and identity omp already knows; ask once.
  defp maybe_request_state(%{resume: resume} = state) when is_binary(resume),
    do: request(state, "get_state", %{}, :state)

  defp maybe_request_state(state), do: state

  defp request(state, type, fields, kind) do
    seq = state.seq + 1
    id = "lemon-#{seq}"
    write(state, Rpc.command(type, id, fields))

    timer =
      case kind do
        :ignore -> nil
        _ -> Process.send_after(self(), {:command_timeout, id}, Config.command_timeout_ms())
      end

    entry = %{kind: kind, timer: timer, agent_starts: state.agent_starts}
    %{state | seq: seq, pending: Map.put(state.pending, id, entry)}
  end

  defp write(%{port: nil}, _frame), do: :ok

  defp write(%{port: port}, frame) do
    Port.command(port, Rpc.encode(frame))
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp reply_pending(state, %{kind: {:send, from, _}}, reply),
    do: tap(state, fn _ -> GenServer.reply(from, reply) end)

  defp reply_pending(state, %{kind: {:cancel, from}}, reply),
    do: tap(state, fn _ -> GenServer.reply(from, reply) end)

  defp reply_pending(state, %{kind: {:subagent, from, _limit}}, reply),
    do: tap(state, fn _ -> GenServer.reply(from, reply) end)

  defp reply_pending(state, %{kind: :initial_prompt}, {:error, :outcome_unknown}) do
    # omp never acknowledged the prompt: report it as unknown, not as a failure.
    started(state, {:error, :outcome_unknown})
  end

  defp reply_pending(state, _entry, _reply), do: state

  defp fail_pending(state) do
    Enum.reduce(state.pending, %{state | pending: %{}}, fn {_id, entry}, acc ->
      if entry.timer, do: Process.cancel_timer(entry.timer)
      reply_pending(acc, entry, {:error, :not_running})
    end)
  end

  defp started(%{started: nil} = state, result) do
    reply =
      case result do
        {:ok, _} -> {:ok, Projection.to_wire(state.projection)}
        error -> error
      end

    Enum.each(state.start_waiters, &GenServer.reply(&1, reply))
    %{state | started: reply, start_waiters: []}
  end

  defp started(state, _result), do: state

  defp fail_waiters(%{started: nil} = state, message),
    do: started(state, {:error, {:startup_failed, message}})

  defp fail_waiters(state, _message), do: state

  defp mark_failed(state, message) do
    state
    |> update_projection(
      &Projection.finish(&1, :failed, %{code: nil, reason: :startup_timeout, error: message})
    )
    |> tap(&publish(&1, "exited"))
  end

  defp update_projection(state, fun), do: %{state | projection: fun.(state.projection)}

  ## Timers and publication

  defp schedule_idle(state) do
    state = cancel_idle(state)

    case Config.idle_timeout_ms() do
      0 -> state
      ms -> %{state | idle_timer: Process.send_after(self(), :idle_timeout, ms)}
    end
  end

  defp cancel_idle(%{idle_timer: nil} = state), do: state

  defp cancel_idle(state) do
    Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil}
  end

  defp publish_now(state, reason) do
    if state.publish_timer, do: Process.cancel_timer(state.publish_timer)
    publish(state, reason)
    %{state | publish_timer: nil, last_publish: now_ms()}
  end

  defp schedule_publish(%{publish_timer: nil} = state) do
    wait = max(@publish_interval_ms - (now_ms() - state.last_publish), 0)
    %{state | publish_timer: Process.send_after(self(), :publish, wait)}
  end

  defp schedule_publish(state), do: state

  defp publish(state, reason) do
    Manager.publish(self(), Projection.to_wire(state.projection), reason)
    state
  end

  ## Process management

  defp open_port(opts, stderr_path) do
    executable = Keyword.fetch!(opts, :executable)
    cwd = Keyword.fetch!(opts, :cwd)
    sh = System.find_executable("sh") || "/bin/sh"

    args =
      ["--mode", "rpc", "--cwd", cwd]
      |> add_flag("--model", Keyword.get(opts, :model))
      |> add_flag("--thinking", Keyword.get(opts, :thinking))
      |> add_flag("--approval-mode", Keyword.get(opts, :approval_mode))
      |> add_flag("--resume", Keyword.get(opts, :resume))

    File.mkdir_p!(Path.dirname(stderr_path))

    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:line, @line_bytes},
        {:cd, cwd},
        {:env, scrubbed_env()},
        {:args,
         ["-c", ~s(f="$1"; shift; exec "$@" 2>>"$f"), "lemon-omp", stderr_path, executable | args]}
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> {:ok, port, os_pid}
      _ -> {:error, :no_os_pid}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp add_flag(args, _flag, nil), do: args
  defp add_flag(args, flag, value), do: args ++ [flag, value]

  # Lemon's own credentials (operator/node tokens and other LEMON_* settings)
  # never reach a delegate that runs model-directed shell commands.
  defp scrubbed_env do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "LEMON_"))
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp stderr_path(id) do
    Path.join([System.tmp_dir!(), "lemon-omp-#{System.get_env("USER", "user")}", "#{id}.stderr"])
  end

  defp exit_error(state, code) do
    tail =
      case File.open(state.stderr_path, [:read, :binary]) do
        {:ok, io} ->
          size =
            case File.stat(state.stderr_path) do
              {:ok, %{size: size}} -> size
              _ -> 0
            end

          offset = max(size - @stderr_tail_bytes, 0)

          data =
            case :file.pread(io, offset, @stderr_tail_bytes) do
              {:ok, data} -> data
              _ -> ""
            end

          File.close(io)
          data |> Projection.clean(@stderr_tail_bytes) |> String.trim()

        _ ->
          ""
      end

    if tail == "",
      do: "omp exited with status #{code}",
      else: "omp exited with status #{code}: #{tail}"
  end

  defp stop_process(%{port: port, os_pid: os_pid}) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if is_integer(os_pid) and wait_exit(os_pid, @exit_grace_ms) == :alive do
      descendants = descendant_pids(os_pid)
      signal(["-TERM" | Enum.map([os_pid | descendants], &to_string/1)])

      if wait_exit(os_pid, 1_000) == :alive do
        signal([
          "-KILL" | Enum.map([os_pid | descendant_pids(os_pid) ++ descendants], &to_string/1)
        ])
      end
    end

    :ok
  end

  defp wait_exit(os_pid, budget) when budget <= 0,
    do: if(alive?(os_pid), do: :alive, else: :gone)

  defp wait_exit(os_pid, budget) do
    if alive?(os_pid) do
      Process.sleep(50)
      wait_exit(os_pid, budget - 50)
    else
      :gone
    end
  end

  defp alive?(os_pid) do
    case System.find_executable("kill") do
      nil -> false
      kill -> match?({_, 0}, System.cmd(kill, ["-0", to_string(os_pid)], stderr_to_stdout: true))
    end
  end

  defp signal(args) do
    case System.find_executable("kill") do
      nil -> :ok
      kill -> System.cmd(kill, args, stderr_to_stdout: true)
    end

    :ok
  end

  defp descendant_pids(parent) do
    case System.find_executable("pgrep") do
      nil ->
        []

      pgrep ->
        case System.cmd(pgrep, ["-P", to_string(parent)], stderr_to_stdout: true) do
          {output, 0} ->
            children =
              output
              |> String.split()
              |> Enum.flat_map(fn value ->
                case Integer.parse(value) do
                  {pid, ""} when pid > 0 -> [pid]
                  _ -> []
                end
              end)

            children ++ Enum.flat_map(children, &descendant_pids/1)

          _ ->
            []
        end
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
