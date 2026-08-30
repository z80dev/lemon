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

  defstruct [:node, :invoke_id, :sink_pid, :run_ref, :request, :timeout_ms]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def cancel(pid, reason \\ :user_requested) do
    GenServer.call(pid, {:cancel, reason})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    node = Keyword.fetch!(opts, :node)
    request = Keyword.fetch!(opts, :request)
    sink_pid = Keyword.fetch!(opts, :sink_pid)
    run_ref = Keyword.fetch!(opts, :run_ref)
    run_opts = Keyword.get(opts, :opts, %{})
    timeout_ms = get_opt(run_opts, :remote_timeout_ms) || @default_timeout_ms

    {:ok,
     %__MODULE__{
       node: node,
       request: request,
       timeout_ms: timeout_ms,
       sink_pid: sink_pid,
       run_ref: run_ref
     }, {:continue, :invoke}}
  end

  @impl true
  def handle_continue(:invoke, state) do
    with {:ok, payload} <- RemoteRequestCodec.encode(state.request),
         {:ok, invoke_id} <-
           NodeRegistry.invoke(state.node, @method, payload,
             recipient: self(),
             timeout_ms: state.timeout_ms
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
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:lemon_node_result, invoke_id, {:ok, result}}, %{invoke_id: invoke_id} = state) do
    case RemoteRequestCodec.decode_result(result) do
      {:ok, completed} -> emit_completed(state, completed)
      {:error, reason} -> emit_error(state, reason)
    end

    {:stop, :normal, state}
  end

  def handle_info(
        {:lemon_node_result, invoke_id, {:error, reason}},
        %{invoke_id: invoke_id} = state
      ) do
    emit_error(state, reason)
    {:stop, :normal, state}
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
end
