defmodule LemonCore.Rpc.Client do
  @moduledoc """
  Transport-independent request ownership for local RPC peers.

  The owning driver retains protocol policy and subprocess cleanup. It supplies
  a framing module and a nonblocking `:send` function (or a transport behaviour),
  feeds incoming bytes with `feed/2`, and completes decoded responses with
  `complete/3`. Calls retain the original caller monitor, not a driver monitor.
  No request is replayed after timeout or transport loss.

  `:ready` defaults to true. Handshaking drivers pass false, then call `ready/1`;
  `:connect_timeout` bounds that handshake. Notifications and reverse requests
  are delivered to the owner as `{:rpc_message, message}`. A driver can instead
  supply `:handler` and `:task_supervisor` to execute them outside its mailbox.
  The handler is an arity-two function or a `LemonCore.Rpc.Handler` module;
  replies use `send_message/2`. Request removal sends
  `{:rpc_finished, id, reason}` to the owner.

  `dispatch/6` separates the monitored original caller from a driver's reply
  relay address. `complete/3` returns `{:error, :not_found}` for late responses.
  `take_buffer/1` transfers and clears an unfinished frame at transport teardown
  for drivers with protocol-specific diagnostic-tail handling.
  """
  @behaviour :gen_statem

  def start_link(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def dispatch(client, id, payload, from, timeout \\ nil),
    do: dispatch(client, id, payload, from, timeout, elem(from, 0))

  def dispatch(client, id, payload, from, timeout, monitor_pid),
    do: :gen_statem.call(client, {:dispatch, id, payload, from, timeout, monitor_pid})

  def complete(client, id, result), do: :gen_statem.call(client, {:complete, id, result})
  def take_buffer(client), do: :gen_statem.call(client, :take_buffer)
  def cancel(client, id), do: :gen_statem.call(client, {:cancel, id})
  def fail_all(client, result), do: :gen_statem.call(client, {:fail_all, result})
  def pending_count(client), do: :gen_statem.call(client, :pending_count)
  def ready(client), do: :gen_statem.call(client, :ready)
  def feed(client, bytes), do: :gen_statem.cast(client, {:data, bytes})
  def peer_down(client, reason), do: :gen_statem.cast(client, {:peer_down, reason})
  def send_message(client, payload), do: :gen_statem.call(client, {:send, payload})

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    peer = Keyword.get(opts, :peer)

    peer_ref =
      cond do
        is_pid(peer) -> Process.monitor(peer)
        is_port(peer) -> :erlang.monitor(:port, peer)
        true -> nil
      end

    data = %{
      owner: owner,
      owner_ref: Process.monitor(owner),
      peer: peer,
      peer_ref: peer_ref,
      framing: Keyword.fetch!(opts, :framing),
      send: Keyword.get(opts, :send),
      transport: Keyword.get(opts, :transport),
      transport_state: Keyword.get(opts, :transport_state),
      handler: Keyword.get(opts, :handler),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      pending: %{},
      buffer: "",
      timeout: Keyword.get(opts, :timeout, 30_000),
      connect_timeout: Keyword.get(opts, :connect_timeout, 30_000)
    }

    {:ok, :disconnected, data,
     [{:next_event, :internal, {:connect, Keyword.get(opts, :ready, true)}}]}
  end

  @impl true
  def handle_event(:internal, {:connect, ready?}, :disconnected, data) do
    state = if ready?, do: :ready, else: :initializing
    actions = if ready?, do: [], else: [{:state_timeout, data.connect_timeout, :connect_timeout}]
    {:next_state, state, data, actions}
  end

  def handle_event(:state_timeout, :connect_timeout, :initializing, data) do
    {:stop, :normal, fail(data, {:error, :connect_timeout})}
  end

  def handle_event({:call, from}, :ready, _state, data),
    do: {:next_state, :ready, data, [{:reply, from, :ok}]}

  def handle_event({:call, from}, :pending_count, _state, data),
    do: {:keep_state_and_data, [{:reply, from, map_size(data.pending)}]}

  def handle_event({:call, from}, :take_buffer, _state, data),
    do: {:keep_state, %{data | buffer: ""}, [{:reply, from, data.buffer}]}

  def handle_event(
        {:call, from},
        {:dispatch, id, payload, caller, timeout, monitor_pid},
        state,
        data
      )
      when state in [:initializing, :ready] do
    if Map.has_key?(data.pending, id) do
      {:keep_state_and_data, [{:reply, from, {:error, :duplicate_id}}]}
    else
      case transmit(data, payload) do
        :ok ->
          monitor = Process.monitor(monitor_pid)
          token = make_ref()
          timeout = if is_nil(timeout), do: data.timeout, else: timeout

          timer =
            if timeout == :infinity,
              do: nil,
              else: Process.send_after(self(), {:deadline, id, token}, timeout)

          entry = %{from: caller, monitor: monitor, timer: timer, token: token}

          {:keep_state, %{data | pending: Map.put(data.pending, id, entry)},
           [{:reply, from, :ok}]}

        {:error, _} = error ->
          {:keep_state_and_data, [{:reply, from, error}]}
      end
    end
  end

  def handle_event({:call, from}, {:complete, id, result}, _state, data) do
    {entry, data} = pop(data, id, :response)
    if entry, do: :gen_statem.reply(entry.from, result)
    reply = if entry, do: :ok, else: {:error, :not_found}
    {:keep_state, data, [{:reply, from, reply}]}
  end

  def handle_event({:call, from}, {:cancel, id}, _state, data) do
    {_entry, data} = pop(data, id, :cancelled)
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:fail_all, result}, _state, data),
    do: {:keep_state, fail(data, result), [{:reply, from, :ok}]}

  def handle_event({:call, from}, {:send, payload}, _state, data),
    do: {:keep_state_and_data, [{:reply, from, transmit(data, payload)}]}

  def handle_event(:cast, {:data, bytes}, _state, data) do
    case data.framing.decode(data.buffer <> bytes) do
      {:ok, messages, buffer} ->
        Enum.each(messages, &deliver(data, &1))
        {:keep_state, %{data | buffer: buffer}}

      {:error, _reason} ->
        {:stop, :normal, fail(data, {:error, :invalid_frame})}
    end
  end

  def handle_event(:info, {:deadline, id, token}, _state, data) do
    case Map.get(data.pending, id) do
      %{token: ^token} ->
        {entry, data} = pop(data, id, :timeout)
        :gen_statem.reply(entry.from, {:error, :timeout})
        {:keep_state, data}

      _ ->
        {:keep_state_and_data, []}
    end
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, _state, data)
      when ref == data.owner_ref or ref == data.peer_ref,
      do: {:stop, :normal, fail(data, {:error, :connection_closed})}

  def handle_event(:info, {:DOWN, ref, :port, _port, _reason}, _state, %{peer_ref: ref} = data),
    do: {:stop, :normal, fail(data, {:error, :connection_closed})}

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, _state, data) do
    data =
      Enum.reduce(data.pending, data, fn {id, entry}, acc ->
        if entry.monitor == ref, do: elem(pop(acc, id, :caller_down), 1), else: acc
      end)

    {:keep_state, data}
  end

  def handle_event(:cast, {:peer_down, _reason}, _state, data),
    do: {:stop, :normal, fail(data, {:error, :connection_closed})}

  def handle_event(:info, {:EXIT, _pid, _reason}, _state, data),
    do: {:stop, :normal, fail(data, {:error, :connection_closed})}

  def handle_event(_type, _event, _state, _data), do: {:keep_state_and_data, []}

  @impl true
  def terminate(_reason, _state, data) do
    fail(data, {:error, :connection_closed})
    if data.transport, do: data.transport.close(data.transport_state)
    :ok
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, state}
      {key, _value} when key in [:queue, :postponed, :log] -> {key, []}
      {key, _value} -> {key, :redacted}
    end)
  end

  defp transmit(data, payload) do
    with {:ok, bytes} <- data.framing.encode(payload) do
      if data.transport,
        do: data.transport.send(data.transport_state, bytes),
        else: data.send.(bytes)
    end
  catch
    _kind, _reason -> {:error, :send_failed}
  end

  defp deliver(%{handler: nil, owner: owner}, message), do: send(owner, {:rpc_message, message})

  defp deliver(data, message) do
    client = self()

    case Task.Supervisor.start_child(data.task_supervisor, fn ->
           try do
             reply = fn payload -> send_message(client, payload) end

             if is_function(data.handler, 2),
               do: data.handler.(message, reply),
               else: data.handler.handle_message(message, reply)
           catch
             _kind, _reason -> send(data.owner, {:rpc_handler_failed, :handler_failed})
           end
         end) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> send(data.owner, {:rpc_handler_failed, :handler_unavailable})
    end
  end

  defp pop(data, id, reason) do
    case Map.pop(data.pending, id) do
      {nil, _pending} ->
        {nil, data}

      {entry, pending} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        Process.demonitor(entry.monitor, [:flush])
        send(data.owner, {:rpc_finished, id, reason})
        {entry, %{data | pending: pending}}
    end
  end

  defp fail(data, result) do
    Enum.reduce(Map.keys(data.pending), data, fn id, acc ->
      {entry, acc} = pop(acc, id, :connection_closed)
      :gen_statem.reply(entry.from, result)
      acc
    end)
  end
end
