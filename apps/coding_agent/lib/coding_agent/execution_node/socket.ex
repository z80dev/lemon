defmodule CodingAgent.ExecutionNode.Socket do
  @moduledoc """
  Reconnecting owner of an execution node's WebSocket transport.

  Each connection authenticates afresh. Reconnect backoff is a timer in this
  GenServer, not a blocked WebSockex callback, so `stop/1` is handled immediately
  even during the sixty-second authentication backoff. Its stable PID remains
  the worker's socket identity across transport replacements.
  """

  use GenServer

  alias CodingAgent.ExecutionNode.Socket.Transport

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec request(pid(), String.t(), map(), term(), pos_integer()) :: String.t()
  def request(pid, method, params, tag, timeout_ms \\ 10_000)
      when is_pid(pid) and is_binary(method) and is_map(params) do
    id = LemonCore.Id.uuid()
    GenServer.cast(pid, {:request, id, method, params, tag, timeout_ms})
    id
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid), do: GenServer.cast(pid, :stop)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{opts: opts, transport: nil, reconnect: nil, timer: nil}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_cast(:stop, state), do: {:stop, :normal, state}

  def handle_cast({:request, id, method, params, tag, timeout_ms}, state) do
    if state.transport && Process.alive?(state.transport) do
      WebSockex.cast(state.transport, {:request, id, method, params, tag, timeout_ms})
    else
      deliver_disconnected(state, tag)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:execution_node_socket, transport, message}, %{transport: transport} = state) do
    send(Keyword.fetch!(state.opts, :owner), {:execution_node_socket, self(), message})
    {:noreply, state}
  end

  def handle_info(
        {:execution_node_reconnect, transport, delay, failures, attempt},
        %{transport: transport} = state
      ) do
    opts = Keyword.merge(state.opts, connect_failures: failures, reconnect_attempt: attempt)
    {:noreply, %{state | opts: opts, reconnect: delay}}
  end

  def handle_info({:EXIT, transport, _reason}, %{transport: transport, reconnect: delay} = state)
      when is_integer(delay) do
    token = make_ref()
    timer = Process.send_after(self(), {:reconnect, token}, delay)
    {:noreply, %{state | transport: nil, reconnect: nil, timer: {timer, token}}}
  end

  def handle_info({:EXIT, transport, reason}, %{transport: transport} = state) do
    {:stop, reason, %{state | transport: nil}}
  end

  def handle_info({:reconnect, token}, %{timer: {_timer, token}} = state),
    do: connect(%{state | timer: nil})

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    if state.transport, do: Process.exit(state.transport, :shutdown)
    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :private_node_transport)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defp connect(state) do
    case Transport.start_link(Keyword.put(state.opts, :owner, self())) do
      {:ok, transport} -> {:noreply, %{state | transport: transport}}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp deliver_disconnected(_state, {:native_reply, recipient, ref}) do
    send(recipient, {:native_controller_reply, ref, {:error, :disconnected}})
  end

  defp deliver_disconnected(state, tag) do
    send(
      Keyword.fetch!(state.opts, :owner),
      {:execution_node_socket, self(), {:response, tag, {:error, :disconnected}}}
    )
  end
end
