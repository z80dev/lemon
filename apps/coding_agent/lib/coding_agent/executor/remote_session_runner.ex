defmodule CodingAgent.Executor.RemoteSessionRunner do
  @moduledoc """
  Bridges one native execution to a live named node.

  The run owner handles lifecycle signaling while `LemonAgent.NodeRegistry`
  owns targeting, timeout, disconnect, and cancellation of the remote
  invocation. Live events traverse the normal executor sink (and therefore the
  run/session Bus topics); terminal results remain a separate final outcome.

  A session-bound run is dispatched with `session_lifecycle_admission: true`:
  its invocation stays session presence after this runner reports a terminal
  outcome (cancel, timeout, disconnect), until the node proves the run stopped.
  """

  use GenServer

  @impl true
  def format_status(status) do
    LemonCore.StatusRedaction.gen_server(status, [:node, :run_id, :session_key, :agent_id])
  end

  import CodingAgent.Executor, only: [get_opt: 2]

  alias CodingAgent.Executor.{RemoteEventCodec, RemoteRequestCodec}
  alias CodingAgent.Executor.Event
  alias LemonAgent.NodeRegistry

  @engine "lemon"
  @method "coding_agent.run"
  @default_timeout_ms 30 * 60 * 1_000
  @default_control_timeout_ms 5_000

  defstruct [
    :node,
    :invoke_id,
    :sink_pid,
    :run_ref,
    :request,
    :timeout_ms,
    :control_timeout_ms,
    :run_id,
    :session_key,
    :agent_id,
    :invocation_context_key,
    event_seq: 0,
    approvals: %{},
    pending_controls: %{}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # A cast: the run owner that requests cancellation never waits on this
  # runner; it holds its permit until the runner exits or its drain deadline.
  def cancel(pid, reason \\ :user_requested) do
    GenServer.cast(pid, {:cancel, reason})
  end

  @spec steer(pid(), String.t()) :: :ok | {:error, term()}
  def steer(pid, text), do: control(pid, :steer, text)

  @spec redirect(pid(), String.t()) :: :ok | {:error, term()}
  def redirect(pid, text), do: control(pid, :redirect, text)

  defp control(pid, operation, text) do
    GenServer.call(pid, {:control, operation, text}, @default_control_timeout_ms + 2_000)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :terminal}
  end

  @impl true
  def init(opts) do
    node = Keyword.fetch!(opts, :node)
    request = Keyword.fetch!(opts, :request)
    sink_pid = Keyword.fetch!(opts, :sink_pid)
    run_ref = Keyword.fetch!(opts, :run_ref)
    run_opts = Keyword.get(opts, :opts, %{})
    timeout_ms = get_opt(run_opts, :remote_timeout_ms) || @default_timeout_ms

    control_timeout_ms = control_timeout(get_opt(run_opts, :remote_control_timeout_ms))
    meta = request.meta || %{}

    {:ok,
     %__MODULE__{
       node: node,
       request: request,
       timeout_ms: timeout_ms,
       control_timeout_ms: control_timeout_ms,
       sink_pid: sink_pid,
       run_ref: run_ref,
       run_id: request.run_id,
       session_key: request.session_key,
       agent_id:
         meta[:agent_id] || meta["agent_id"] ||
           LemonCore.SessionKey.agent_id(request.session_key || ""),
       invocation_context_key:
         Map.get(meta, :invocation_context_key, Map.get(meta, "invocation_context_key"))
     }, {:continue, :invoke}}
  end

  @impl true
  def handle_continue(:invoke, state) do
    max_payload = protocol_max_payload()

    with {:ok, destination} <- privacy_destination(state.request, state.node),
         :ok <- validate_destination_protocol(destination, state.node),
         {:ok, payload} <-
           RemoteRequestCodec.encode(canonical_request(state.request), max_bytes: max_payload),
         {:ok, invoke_id} <- invoke_destination(destination, state, payload, max_payload) do
      started =
        Event.started(%{
          engine: @engine,
          resume: nil,
          meta: %{node: state.node, cwd: payload["cwd"]}
        })

      send(state.sink_pid, {:engine_event, state.run_ref, started})

      {:noreply, %{state | invoke_id: invoke_id, request: nil}}
    else
      {:error, reason} ->
        emit_error(state, reason)
        {:stop, :normal, state}
    end
  end

  defp canonical_request(request) do
    meta = request.meta || %{}

    meta =
      if not CodingAgent.Tools.Task.InvocationAuthority.managed_metadata?(meta) and
           not Map.has_key?(meta, :invocation_context_key) and
           Map.has_key?(meta, "invocation_context_key"),
         do:
           Map.put(meta, :invocation_context_key, meta["invocation_context_key"])
           |> Map.delete("invocation_context_key"),
         else: meta

    %{request | meta: meta}
  end

  defp privacy_destination(request, selector) do
    meta = request.meta || %{}

    protected? = RemoteRequestCodec.protected_meta?(meta)

    if protected? do
      resolved = NodeRegistry.resolve_id(selector)

      with {:ok, node} <- resolved,
           capabilities when is_map(capabilities) <-
             Map.get(node.metadata, :capabilities, Map.get(node.metadata, "capabilities")),
           %{"coding_agent.run" => %{"nativePrivacyContext" => %{"version" => 1}}} <- capabilities,
           true <-
             is_nil(meta[:native_destination_pid]) || meta[:native_destination_pid] == node.pid,
           true <-
             is_nil(meta[:native_destination_generation]) ||
               meta[:native_destination_generation] == node.generation do
        {:ok, node}
      else
        _ -> {:error, {:native_privacy_context_unsupported, selector}}
      end
    else
      case NodeRegistry.resolve(selector) do
        {:ok, node} -> {:ok, node}
        {:error, _} -> {:error, {:node_offline, selector}}
      end
    end
  catch
    _, _ -> {:error, :native_privacy_context_unavailable}
  end

  defp validate_destination_protocol(node, selector) do
    if NodeRegistry.native_privacy_context_supported?(node.metadata),
      do: :ok,
      else: {:error, {:execution_context_unsupported, selector}}
  end

  defp invoke_destination(node, state, payload, max_payload) do
    session_key = payload["sessionKey"]

    NodeRegistry.invoke_node(node.id, @method, payload,
      recipient: self(),
      timeout_ms: state.timeout_ms,
      max_payload_bytes: max_payload,
      expected_pid: node.pid,
      expected_generation: node.generation,
      required_native_privacy_context: 1,
      session_lifecycle_admission: is_binary(session_key) and session_key != ""
    )
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    :ok = NodeRegistry.cancel(state.invoke_id, reason)
    state = reply_pending_controls(state, {:error, :cancelled})
    {:stop, :normal, state}
  end

  @impl true
  def handle_call({:control, _operation, _text}, _from, %{invoke_id: nil} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:control, operation, text}, from, state) do
    case NodeRegistry.control(state.invoke_id, operation, text,
           recipient: self(),
           timeout_ms: state.control_timeout_ms
         ) do
      {:ok, control_id} ->
        pending_controls = Map.put(state.pending_controls, control_id, from)
        {:noreply, %{state | pending_controls: pending_controls}}

      {:error, :terminal} ->
        {:reply, {:error, :terminal}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:lemon_node_result, invoke_id, {:ok, result}}, %{invoke_id: invoke_id} = state) do
    case RemoteRequestCodec.decode_result(result) do
      {:ok, completed} -> emit_completed(state, completed)
      {:error, reason} -> emit_error(state, reason)
    end

    {:stop, :normal, reply_pending_controls(state, {:error, :terminal})}
  end

  def handle_info(
        {:lemon_node_result, invoke_id, {:error, reason}},
        %{invoke_id: invoke_id} = state
      ) do
    emit_error(state, reason)
    {:stop, :normal, reply_pending_controls(state, {:error, :terminal})}
  end

  def handle_info(
        {:lemon_node_control_result, control_id, invoke_id, result},
        %{invoke_id: invoke_id} = state
      ) do
    case Map.pop(state.pending_controls, control_id) do
      {nil, _pending_controls} ->
        {:noreply, state}

      {from, pending_controls} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending_controls: pending_controls}}
    end
  end

  def handle_info({:lemon_node_event, invoke_id, seq, event}, %{invoke_id: invoke_id} = state)
      when seq == state.event_seq + 1 do
    state = %{state | event_seq: seq}

    case RemoteEventCodec.decode(event) do
      {:ok, {:delta, text}} ->
        send(state.sink_pid, {:engine_delta, state.run_ref, text})
        {:noreply, state}

      {:ok, {:engine, %{__event__: :started}}} ->
        # The controller already emitted the executor started event on dispatch.
        {:noreply, state}

      {:ok, {:engine, event}} ->
        send(state.sink_pid, {:engine_event, state.run_ref, event})
        {:noreply, state}

      {:ok, {:checkpoint, type, payload}} ->
        send(state.sink_pid, {:engine_checkpoint, state.run_ref, type, payload})
        {:noreply, state}

      {:ok, {:approval, approval}} ->
        {:noreply, request_approval(state, approval)}

      {:error, _reason} ->
        :ok = NodeRegistry.cancel(state.invoke_id, :invalid_remote_event)
        emit_error(state, :invalid_remote_event)
        {:stop, :normal, reply_pending_controls(state, {:error, :terminal})}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Enum.find(state.approvals, fn {_id, approval} -> approval.task.ref == ref end) do
      {worker_id, approval} ->
        Process.demonitor(ref, [:flush])

        decision =
          case result do
            {:ok, :approved, _scope} when approval.once_only ->
              "approve_once"

            {:ok, :approved, scope}
            when scope in [:approve_once, :approve_session, :approve_agent, :approve_global] ->
              Atom.to_string(scope)

            {:ok, :approved, _persisted_scope} ->
              "approve_once"

            # The controller could not confirm its decision: relay it as
            # unknown so the worker settles its waiter without a denial.
            {:error, :outcome_unknown} ->
              "outcome_unknown"

            _ ->
              "deny"
          end

        _ = NodeRegistry.approval(state.invoke_id, worker_id, decision)
        {:noreply, %{state | approvals: Map.delete(state.approvals, worker_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.approvals, fn {_id, approval} -> approval.task.ref == ref end) do
      {worker_id, approval} ->
        _ = LemonCore.ExecApprovals.cancel(approval.controller_id, "remote approval waiter ended")
        _ = NodeRegistry.approval(state.invoke_id, worker_id, "deny")
        {:noreply, %{state | approvals: Map.delete(state.approvals, worker_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.approvals, fn {_worker_id, approval} ->
      _ = Task.shutdown(approval.task, :brutal_kill)
      _ = LemonCore.ExecApprovals.cancel(approval.controller_id, "remote invocation ended")
    end)

    :ok
  end

  defp request_approval(state, approval) do
    worker_id = approval.approval_id

    cond do
      Map.has_key?(state.approvals, worker_id) ->
        state

      map_size(state.approvals) >= 32 ->
        _ = NodeRegistry.approval(state.invoke_id, worker_id, "deny")
        state

      true ->
        controller_id = LemonCore.Id.approval_id()

        remaining =
          case approval.expires_at_ms do
            ms when is_integer(ms) -> max(ms - LemonCore.Clock.now_ms(), 0)
            _ -> 600_000
          end

        params = %{
          approval_id: controller_id,
          run_id: state.run_id,
          session_key: state.session_key,
          agent_id: state.agent_id,
          tool: approval.tool,
          action: approval.action,
          invocation_context_key: state.invocation_context_key,
          rationale: approval.rationale,
          expires_in_ms: min(remaining, 600_000),
          once_only: approval.once_only == true
        }

        owner = self()

        task =
          Task.async(fn ->
            waiter = self()
            spawn(fn -> guard_approval(owner, waiter, controller_id) end)
            LemonCore.ExecApprovals.request(params)
          end)

        entry = %{task: task, controller_id: controller_id, once_only: approval.once_only == true}
        %{state | approvals: Map.put(state.approvals, worker_id, entry)}
    end
  end

  # A brutal owner death skips GenServer.terminate/2. Kill and monitor-confirm
  # the waiter before cancelling its store row, including registration races.
  defp guard_approval(owner, waiter, approval_id) do
    owner_ref = Process.monitor(owner)
    waiter_ref = Process.monitor(waiter)

    receive do
      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        Process.exit(waiter, :kill)

        receive do
          {:DOWN, ^waiter_ref, :process, _pid, _reason} -> :ok
        end

      {:DOWN, ^waiter_ref, :process, _pid, _reason} ->
        Process.demonitor(owner_ref, [:flush])
    end

    _ = LemonCore.ExecApprovals.cancel(approval_id, "remote approval owner ended")
    :ok
  end

  defp emit_completed(state, completed) do
    event =
      Event.completed(%{
        engine: @engine,
        ok: completed.ok,
        answer: completed.answer,
        error: completed.error,
        usage: completed.usage,
        meta: merge_node_meta(completed.meta, state.node),
        resume: completed.resume
      })

    send(state.sink_pid, {:engine_event, state.run_ref, event})
  end

  defp emit_error(state, reason) do
    event =
      Event.completed(%{
        engine: @engine,
        ok: false,
        answer: "",
        error: reason,
        meta: %{node: state.node}
      })

    send(state.sink_pid, {:engine_event, state.run_ref, event})
  end

  defp merge_node_meta(meta, node) when is_map(meta) do
    meta
    |> CodingAgent.Tools.Task.InvocationAuthority.sanitize_child_metadata()
    |> Map.put(:node, node)
  end

  defp merge_node_meta(_meta, node), do: %{node: node}

  # The shared execution JSON bound; the control plane enforces its own frame
  # limit on the wire and rejects anything larger.
  defp protocol_max_payload, do: LemonCore.ToolPolicy.execution_max_bytes()

  # Keep the public GenServer call deadline above every registry acknowledgement
  # deadline so callers receive the registry's explicit timeout result.
  defp control_timeout(value)
       when is_integer(value) and value > 0 and value <= @default_control_timeout_ms,
       do: value

  defp control_timeout(_value), do: @default_control_timeout_ms

  defp reply_pending_controls(state, result) do
    Enum.each(state.pending_controls, fn {_control_id, from} ->
      GenServer.reply(from, result)
    end)

    %{state | pending_controls: %{}}
  end
end
