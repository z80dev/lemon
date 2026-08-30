defmodule CodingAgent.Executor.RemoteSessionRunner do
  @moduledoc """
  Bridges one gateway execution to a live named node.

  The source owns gateway lifecycle signaling while `LemonCore.NodeRegistry`
  owns targeting, timeout, disconnect, and cancellation of the remote
  invocation. The destination returns one JSON-safe terminal result for the
  `coding_agent.run` method.
  """

  use GenServer

  alias CodingAgent.Executor.RemoteRequestCodec
  alias LemonCore.NodeRegistry
  alias LemonGateway.Event

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
    pending_controls: %{}
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def cancel(pid, reason \\ :user_requested) do
    GenServer.call(pid, {:cancel, reason})
  catch
    :exit, _ -> :ok
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

    {:ok,
     %__MODULE__{
       node: node,
       request: request,
       timeout_ms: timeout_ms,
       control_timeout_ms: control_timeout_ms,
       sink_pid: sink_pid,
       run_ref: run_ref
     }, {:continue, :invoke}}
  end

  @impl true
  def handle_continue(:invoke, state) do
    max_payload = protocol_max_payload()

    with {:ok, payload} <- RemoteRequestCodec.encode(state.request, max_bytes: max_payload),
         {:ok, invoke_id} <-
           NodeRegistry.invoke(state.node, @method, payload,
             recipient: self(),
             timeout_ms: state.timeout_ms,
             max_payload_bytes: max_payload
           ) do
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

  @impl true
  def handle_call({:cancel, reason}, _from, state) do
    :ok = NodeRegistry.cancel(state.invoke_id, reason)
    state = reply_pending_controls(state, {:error, :cancelled})
    {:stop, :normal, :ok, state}
  end

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

  def handle_info(_message, state), do: {:noreply, state}

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

  defp merge_node_meta(meta, node) when is_map(meta), do: Map.put(meta, :node, node)
  defp merge_node_meta(_meta, node), do: %{node: node}

  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(_opts, _key), do: nil

  defp protocol_max_payload do
    case Application.get_env(:lemon_control_plane, :max_payload) do
      value when is_integer(value) and value > 0 -> value
      _ -> LemonCore.JSONPayload.default_max_bytes()
    end
  end

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
