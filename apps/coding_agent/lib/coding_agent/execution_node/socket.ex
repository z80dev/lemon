defmodule CodingAgent.ExecutionNode.Socket do
  @moduledoc """
  Reconnecting WebSocket client for a Lemon execution node.

  Every successful TCP/WebSocket connection performs a fresh authenticated
  control-plane `connect` handshake. Request parameters are never logged, and
  status formatting redacts the stored authentication material.
  """

  use WebSockex

  require Logger

  alias CodingAgent.ExecutionNode.Codec

  defstruct [
    :owner,
    :url,
    :connect_params,
    :connect_id,
    :reconnect_delay_ms,
    :ping_interval_ms,
    :ping_token,
    :max_payload_bytes,
    pending: %{},
    stopping: false
  ]

  @type message ::
          {:connected, map()}
          | {:disconnected, term()}
          | {:event, String.t(), map()}
          | {:response, term(), {:ok, term()} | {:error, term()}}
          | {:authentication_error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    url = Keyword.fetch!(opts, :url)
    connect_params = Keyword.fetch!(opts, :connect_params)

    state = %__MODULE__{
      owner: owner,
      url: url,
      connect_params: connect_params,
      reconnect_delay_ms: Keyword.get(opts, :reconnect_delay_ms, 500),
      ping_interval_ms: Keyword.get(opts, :ping_interval_ms, 25_000),
      max_payload_bytes: LemonCore.JSONPayload.default_max_bytes()
    }

    WebSockex.start_link(url, __MODULE__, state,
      async: true,
      handle_initial_conn_failure: true
    )
  end

  @spec request(pid(), String.t(), map(), term(), pos_integer()) :: String.t()
  def request(pid, method, params, tag, timeout_ms \\ 10_000)
      when is_pid(pid) and is_binary(method) and is_map(params) do
    id = LemonCore.Id.uuid()
    WebSockex.cast(pid, {:request, id, method, params, tag, timeout_ms})
    id
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    WebSockex.cast(pid, :stop)
  end

  @impl WebSockex
  def handle_connect(_conn, state) do
    id = LemonCore.Id.uuid()
    ping_token = make_ref()
    send(self(), {:execution_node_send_connect, id})
    schedule_ping(state.ping_interval_ms, ping_token)

    {:ok, %{state | connect_id: id, pending: %{}, stopping: false, ping_token: ping_token}}
  end

  @impl WebSockex
  def handle_frame({:text, data}, state) do
    if byte_size(data) > payload_limit(state) do
      Logger.warning("Execution node closed an oversized control-plane frame")
      {:close, {1009, "payload too large"}, state}
    else
      decode_frame(data, state)
    end
  end

  def handle_frame({_kind, _data}, state), do: {:ok, state}

  defp decode_frame(data, state) do
    case Codec.decode(data) do
      {:ok, {:hello, hello}} ->
        notify(state, {:connected, hello})

        {:ok,
         %{
           state
           | connect_id: nil,
             max_payload_bytes: advertised_payload_limit(hello, state)
         }}

      {:ok, {:event, event, payload}} ->
        notify(state, {:event, event, payload})
        {:ok, state}

      {:ok, {:response, id, {:error, error}}} when id == state.connect_id ->
        notify(state, {:authentication_error, error})
        {:close, {1008, "authentication failed"}, %{state | stopping: true}}

      {:ok, {:response, id, result}} ->
        {pending, rest} = Map.pop(state.pending, id)

        if pending do
          Process.cancel_timer(pending.timer)
          notify(state, {:response, pending.tag, result})
        end

        {:ok, %{state | pending: rest}}

      {:error, reason} ->
        Logger.warning("Execution node ignored invalid control-plane frame: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_cast({:request, id, method, params, tag, timeout_ms}, state) do
    timer = Process.send_after(self(), {:request_timeout, id}, timeout_ms)
    pending = Map.put(state.pending, id, %{tag: tag, timer: timer})
    frame = Codec.encode_request(id, method, params)
    {:reply, {:text, frame}, %{state | pending: pending}}
  end

  def handle_cast(:stop, state) do
    {:close, %{state | stopping: true}}
  end

  @impl WebSockex
  def handle_info(
        {:execution_node_send_connect, id},
        %{connect_id: id} = state
      ) do
    frame = Codec.encode_request(id, "connect", state.connect_params)
    {:reply, {:text, frame}, state}
  end

  def handle_info({:request_timeout, id}, state) do
    {pending, rest} = Map.pop(state.pending, id)
    if pending, do: notify(state, {:response, pending.tag, {:error, :timeout}})
    {:ok, %{state | pending: rest}}
  end

  def handle_info({:execution_node_ping, token}, %{ping_token: token, stopping: false} = state) do
    schedule_ping(state.ping_interval_ms, token)
    {:reply, {:ping, ""}, state}
  end

  def handle_info({:execution_node_ping, _token}, state), do: {:ok, state}

  @impl WebSockex
  def handle_disconnect(_status, %{stopping: true} = state) do
    fail_pending(state, :disconnected)
    {:ok, %{state | pending: %{}, connect_id: nil, ping_token: nil}}
  end

  def handle_disconnect(status, state) do
    reason = Map.get(status, :reason, :disconnected)
    attempt = Map.get(status, :attempt_number, 1)
    fail_pending(state, :disconnected)
    notify(state, {:disconnected, reason})

    delay = min(state.reconnect_delay_ms * max(attempt, 1), 5_000)
    if delay > 0, do: Process.sleep(delay)

    {:reconnect, %{state | pending: %{}, connect_id: nil, ping_token: nil}}
  end

  @impl WebSockex
  def terminate(reason, state) do
    fail_pending(state, {:socket_terminated, reason})
    :ok
  end

  @impl WebSockex
  def format_status(_reason, [_pdict, state]) do
    redacted_params =
      case state.connect_params do
        %{"auth" => _auth} = params -> Map.put(params, "auth", "[REDACTED]")
        params -> params
      end

    %{state | connect_params: redacted_params, pending: Map.keys(state.pending)}
  end

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn {_id, pending} ->
      Process.cancel_timer(pending.timer)
      notify(state, {:response, pending.tag, {:error, reason}})
    end)
  end

  defp notify(state, message) do
    send(state.owner, {:execution_node_socket, self(), message})
  end

  defp schedule_ping(interval_ms, token) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), {:execution_node_ping, token}, interval_ms)
  end

  defp schedule_ping(_interval_ms, _token), do: :ok

  defp advertised_payload_limit(hello, state) do
    case get_in(hello, ["policy", "maxPayload"]) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _ -> payload_limit(state)
    end
  end

  defp payload_limit(%{max_payload_bytes: bytes}) when is_integer(bytes) and bytes > 0, do: bytes
  defp payload_limit(_state), do: LemonCore.JSONPayload.default_max_bytes()
end
