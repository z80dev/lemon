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
  additionally escalates to SIGTERM and SIGKILL for its witnessed process group
  if omp has not exited within a short grace period. Descendants that deliberately
  escape that group are not contained by this cleanup.

  ## Steering and cancellation

  Control messages are acknowledged only after omp answers the correlated
  command with `success: true`. omp's error response becomes `{:rejected, msg}`;
  no answer within the command timeout becomes `:outcome_unknown`, which callers
  must not retry automatically — the command may already have taken effect.

  `LemonCore.Rpc.Client` owns command correlation, deadlines and caller monitors.
  This process retains port ownership, protocol projections and approval dialogs.
  Configuration commands are sequenced by their caller, so a caller that exits
  cannot leave a configuration continuation issuing more commands.
  """

  use GenServer, restart: :temporary, shutdown: 5_000

  @impl true
  def format_status(status) do
    LemonCore.StatusRedaction.gen_server(status, [:os_pid, :seq])
  end

  alias LemonCore.Rpc.{Client, JsonLines}
  alias LemonCore.ProcessGroup
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
          session_dir: String.t() | nil,
          session_source: String.t() | nil,
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

  @spec send_message(pid(), String.t(), :steer | :follow_up | :redirect) ::
          {:ok, map()} | {:error, term()}
  def send_message(pid, message, mode),
    do: safe_call(pid, {:send_message, message, mode}, Config.command_timeout_ms() + 2_000)

  @spec configure(pid(), [{String.t(), String.t(), map()}]) :: {:ok, map()} | {:error, term()}
  def configure(pid, commands), do: configure_next(pid, [], commands)

  @spec cancel(pid()) :: {:ok, map()} | {:error, term()}
  def cancel(pid), do: safe_call(pid, :cancel, Config.command_timeout_ms() + 2_000)

  @spec subagent(pid(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def subagent(pid, subagent_id, limit) do
    case safe_call(pid, {:subagent, subagent_id}, Config.command_timeout_ms() + 2_000) do
      {:ok, data} -> {:ok, Projection.subagent_transcript(data, limit)}
      error -> error
    end
  end

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
    case GenServer.call(pid, message, timeout) do
      {:error, :timeout} -> {:error, :outcome_unknown}
      {:error, reason} when reason in [:connection_closed, :send_failed] -> {:error, :not_running}
      result -> result
    end
  catch
    :exit, {:timeout, _} -> {:error, :outcome_unknown}
    :exit, _reason -> {:error, :not_running}
  end

  defp configure_next(pid, applied, [{field, type, fields} | rest]) do
    case command_call(pid, type, fields) do
      {:ok, _data} -> configure_next(pid, applied ++ [field], rest)
      {:error, reason} -> configure_failed(pid, applied, field, reason)
    end
  end

  defp configure_next(pid, applied, []), do: configure_snapshot(pid, applied, nil)

  defp configure_failed(_pid, [], _field, reason), do: {:error, reason}

  defp configure_failed(_pid, applied, field, :not_running),
    do: configure_error(applied, {field, :not_running})

  defp configure_failed(pid, applied, field, reason),
    do: configure_snapshot(pid, applied, {field, reason})

  defp configure_snapshot(pid, applied, failure) do
    result =
      case command_call(pid, "get_state", %{}) do
        {:ok, data} when is_map(data) ->
          # The response callback publishes the refreshed projection before it
          # can process this call, even though the RPC client replies directly.
          safe_call(pid, :configuration_snapshot, Config.command_timeout_ms() + 2_000)

        {:ok, _data} ->
          {:error, {:rejected, "omp returned an invalid session state"}}

        error ->
          error
      end

    case result do
      {:ok, wire} when is_nil(failure) -> {:ok, wire}
      {:ok, _wire} -> configure_error(applied, failure)
      {:error, reason} -> configure_error(applied, failure || {"snapshot", reason})
    end
  end

  defp command_call(pid, type, fields),
    do: safe_call(pid, {:command, type, fields}, Config.command_timeout_ms() + 2_000)

  defp configure_error(applied, {field, reason}),
    do: {:error, {:partially_applied, applied, field, reason}}

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
      rpc_client: nil,
      initial_prompt_id: nil,
      redirects: %{},
      approvals: %{},
      seq: 0,
      idle_timer: nil,
      publish_timer: nil,
      last_publish: 0,
      close_reason: nil,
      malformed: 0,
      agent_starts: 0
    }

    case open_port(opts, stderr_path) do
      {:ok, port, os_pid} ->
        {:ok, client} =
          Client.start_link(
            owner: self(),
            peer: port,
            framing: JsonLines,
            send: &send_bytes(port, &1),
            ready: false,
            connect_timeout: Config.ready_timeout_ms(),
            timeout: Config.command_timeout_ms()
          )

        state = %{state | port: port, os_pid: os_pid, rpc_client: client}
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
    type =
      case {state.projection.status, mode} do
        {:running, :follow_up} -> "follow_up"
        {:running, :redirect} -> "abort_and_prompt"
        {:running, _steer} -> "steer"
        {_idle, _mode} -> "prompt"
      end

    {:noreply, request(state, type, %{"message" => message}, from)}
  end

  def handle_call({:command, _type, _fields}, _from, %{ready?: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:command, type, fields}, from, state),
    do: {:noreply, request(state, type, fields, from)}

  def handle_call(:configuration_snapshot, _from, state),
    do: {:reply, {:ok, Projection.to_wire(state.projection)}, state}

  def handle_call(:cancel, _from, %{projection: %{status: status}} = state)
      when status != :running,
      do: {:reply, {:error, :no_active_turn}, state}

  def handle_call(:cancel, from, state),
    do: {:noreply, request(state, "abort", %{}, from)}

  def handle_call({:subagent, _id}, _from, %{ready?: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:subagent, id}, from, state) do
    {:noreply, request(state, "get_subagent_messages", %{"subagentId" => id}, from)}
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
    fail_commands(state)
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, client, _reason}, %{rpc_client: client, ready?: false} = state) do
    state =
      mark_failed(%{state | close_reason: :startup_timeout}, "omp did not become ready in time")

    {:stop, :normal, fail_waiters(state, "omp did not become ready in time")}
  end

  def handle_info({:EXIT, client, _reason}, %{rpc_client: client} = state) do
    state =
      update_projection(
        state,
        &Projection.finish(&1, :failed, %{code: nil, reason: :connection_closed})
      )

    {:stop, :normal, fail_waiters(state, "omp connection closed")}
  end

  def handle_info({:rpc_finished, id, reason}, state)
      when reason in [:timeout, :caller_down, :cancelled, :connection_closed] do
    # An abandoned redirect must not hold the session running forever.
    state =
      if is_map_key(state.redirects, id) do
        state = clear_redirect(state, id)

        if state.projection.settling and not state.projection.redirecting,
          do: handle_frame(state, {:event, "session_settled", %{}}),
          else: state
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({{:rpc_reply, :initial_prompt}, {:error, :timeout}}, state),
    do: {:noreply, started(state, {:error, :outcome_unknown})}

  def handle_info({{:rpc_reply, :initial_prompt}, {:error, reason}}, state)
      when reason in [:connection_closed, :send_failed],
      do: {:noreply, fail_waiters(state, "omp connection closed")}

  def handle_info({{:rpc_reply, {pid, _tag} = caller}, result}, state) when is_pid(pid) do
    GenServer.reply(caller, result)
    {:noreply, state}
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
    fail_commands(state)
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
    case rpc_call(fn -> Client.ready(state.rpc_client) end) do
      :ok ->
        state = %{state | ready?: true}

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

      {:error, :connection_closed} ->
        # The linked client's EXIT will finalize the startup failure.
        state
    end
  end

  defp handle_frame(state, {:response, id, command, result}) do
    entry = request_context(state, id)

    case rpc_call(fn -> Client.complete(state.rpc_client, id, response_reply(entry, result)) end) do
      :ok ->
        handle_response(state, entry, result)

      {:error, :not_found} ->
        handle_late_response(state, id, command, result)

      {:error, :connection_closed} ->
        state
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
      if type == "agent_start" do
        # Keep the current redirect's id for omp's asynchronous prompt failure,
        # but discard ids from earlier turns. A new start releases the idle guard.
        redirects = Map.reject(state.redirects, fn {_id, seen} -> seen < state.agent_starts end)
        %{state | agent_starts: state.agent_starts + 1, redirects: redirects}
      else
        state
      end

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
    |> update_projection(fn projection ->
      projection = put_in(projection.output.error, Projection.clean(message, 1_000))
      Projection.settle(projection)
    end)
    |> schedule_idle()
  end

  defp handle_response(state, %{kind: {:send, delivery}} = entry, {:ok, _data}) do
    case delivery do
      "prompt" ->
        state |> cancel_idle() |> mark_running_after_ack(entry) |> publish_now("updated")

      "redirect" ->
        state |> cancel_idle() |> mark_running_after_ack(entry) |> publish_now("redirected")

      _ ->
        state
    end
  end

  defp handle_response(state, %{kind: {:send, delivery}} = entry, {:error, _message, _code}) do
    if delivery == "redirect" do
      state = clear_redirect(state, entry.id)

      if state.projection.settling and not state.projection.redirecting do
        handle_frame(state, {:event, "session_settled", %{}})
      else
        schedule_publish(state)
      end
    else
      state
    end
  end

  defp handle_response(state, %{kind: :stats}, {:ok, data}) when is_map(data),
    do: state |> update_projection(&Projection.apply_stats(&1, data)) |> schedule_publish()

  defp handle_response(state, %{kind: :state}, {:ok, data}) when is_map(data),
    do: state |> update_projection(&Projection.apply_state(&1, data)) |> publish_now("configured")

  defp handle_response(state, _entry, _result), do: state

  # abort_and_prompt acknowledges before its new prompt finishes. omp can then
  # send a second, failing response with the same id: it is a turn error, not a
  # second command reply. Keep the caller's accepted result and settle the turn.
  defp handle_late_response(state, id, "abort_and_prompt", {:error, message, _code})
       when is_map_key(state.redirects, id) do
    state
    |> clear_redirect(id)
    |> handle_frame(
      {:event, "prompt_result", %{"status" => "error", "error" => %{"message" => message}}}
    )
  end

  defp handle_late_response(state, _id, _command, _result), do: state

  defp clear_redirect(state, id) do
    redirects = Map.delete(state.redirects, id)
    redirecting = Enum.any?(redirects, fn {_id, seen} -> seen == state.agent_starts end)

    %{state | redirects: redirects}
    |> update_projection(&%{&1 | redirecting: redirecting})
  end

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

  defp request(state, type, fields, caller) do
    seq = state.seq + 1
    # Relay replies through the owner so the acknowledged projection is published
    # before a caller can read it. The RPC client still monitors the real caller.
    id = "lemon-#{seq}-#{state.agent_starts}-#{type}"
    from = {self(), {:rpc_reply, caller}}
    monitor_pid = if is_atom(caller), do: self(), else: elem(caller, 0)
    state = %{state | seq: seq}
    state = if caller == :initial_prompt, do: %{state | initial_prompt_id: id}, else: state

    case rpc_call(fn ->
           Client.dispatch(
             state.rpc_client,
             id,
             Rpc.command(type, id, fields),
             from,
             Config.command_timeout_ms(),
             monitor_pid
           )
         end) do
      :ok when type == "abort_and_prompt" ->
        %{state | redirects: Map.put(state.redirects, id, state.agent_starts)}
        |> update_projection(&%{&1 | redirecting: true})

      :ok ->
        state

      {:error, _reason} = error ->
        GenServer.reply(from, error)
        state
    end
  end

  defp request_context(state, id) when is_binary(id) do
    with ["lemon", _seq, generation, type] <- String.split(id, "-", parts: 4),
         {agent_starts, ""} <- Integer.parse(generation) do
      kind =
        cond do
          id == state.initial_prompt_id -> :initial_prompt
          type == "get_session_stats" -> :stats
          type == "get_state" -> :state
          type == "abort" -> :cancel
          type in ["prompt", "steer", "follow_up", "abort_and_prompt"] -> {:send, delivery(type)}
          true -> :ignore
        end

      %{id: id, kind: kind, agent_starts: agent_starts}
    else
      _ -> nil
    end
  end

  defp request_context(_state, _id), do: nil

  defp response_reply(_entry, {:error, message, _code}),
    do: {:error, {:rejected, Projection.clean(message, 500)}}

  defp response_reply(%{kind: {:send, delivery}}, {:ok, _data}),
    do: {:ok, %{"delivery" => delivery}}

  defp response_reply(%{kind: :cancel}, {:ok, _data}),
    do: {:ok, %{"cancelled" => true}}

  defp response_reply(_entry, result), do: result

  defp delivery("abort_and_prompt"), do: "redirect"
  defp delivery("follow_up"), do: "followUp"
  defp delivery(type), do: type

  defp write(state, frame),
    do: rpc_call(fn -> Client.send_message(state.rpc_client, frame) end)

  defp send_bytes(port, bytes) do
    Port.command(port, bytes)
    :ok
  rescue
    ArgumentError -> {:error, :connection_closed}
  end

  defp fail_commands(state) do
    rpc_call(fn -> Client.fail_all(state.rpc_client, {:error, :connection_closed}) end)
    flush_command_replies()
  end

  # Teardown stops this relay before its normal mailbox loop can forward replies.
  defp flush_command_replies do
    receive do
      {{:rpc_reply, {pid, _tag} = caller}, result} when is_pid(pid) ->
        GenServer.reply(caller, result)
        flush_command_replies()
    after
      0 -> :ok
    end
  end

  defp rpc_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :connection_closed}
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
    session_dir = Keyword.get_lazy(opts, :session_dir, &Config.session_dir/0)
    prepare_session_dir(session_dir, Keyword.get(opts, :session_source))

    args =
      ["--mode", "rpc", "--cwd", cwd]
      |> add_flag("--session-dir", session_dir)
      |> add_flag("--model", Keyword.get(opts, :model))
      |> add_flag("--thinking", Keyword.get(opts, :thinking))
      |> add_flag("--approval-mode", Keyword.get(opts, :approval_mode))
      |> add_flag("--resume", Keyword.get(opts, :resume))

    File.mkdir_p!(Path.dirname(stderr_path))
    # Track the RPC process without claiming containment of delegate tools that
    # can launch independently owned sessions.
    LemonCore.NativeProcess.unsupported!()

    port =
      LemonCore.NativeProcess.open({:spawn_executable, sh}, [
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

  # Discovery and legacy resume never create/chmod omp's own history buckets.
  defp prepare_session_dir(nil, _source), do: :ok
  defp prepare_session_dir(_dir, "omp"), do: :ok

  defp prepare_session_dir(dir, _source) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
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
    # Retain the birth-bound group witness before EOF can reparent its children.
    identity =
      case ProcessGroup.capture_workload_group(os_pid) do
        {:ok, identity} ->
          identity

        {:error, _} ->
          if is_integer(os_pid), do: ProcessGroup.terminate(os_pid, grace_ms: 1_000)
          nil
      end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if identity do
      case wait_exit(identity, System.monotonic_time(:millisecond) + @exit_grace_ms) do
        :gone -> :ok
        {_, observed} -> ProcessGroup.terminate(observed, grace_ms: 1_000)
      end
    end

    :ok
  end

  # Count native observation and durable-launch overhead against the grace,
  # rather than subtracting only the sleeps between potentially slow probes.
  defp wait_exit(identity, deadline) do
    case ProcessGroup.workload_group_status(identity) do
      :terminated ->
        :gone

      {:alive, observed} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(50, remaining))
          wait_exit(observed, deadline)
        else
          {:alive, observed}
        end

      {:unknown, _} = unknown ->
        unknown
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
