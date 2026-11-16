defmodule CodingAgent.Tools.Task.ChildInbox do
  @moduledoc """
  A task-local mailbox for messages admitted before its session attaches.

  The existing caller policy allows 64 pending messages and 256 KiB of encoded
  content, including peer envelopes. `Control` validates the separate 32 KiB
  UTF-8 body limit before constructing an envelope. Only the owning coordinator
  can check or consume admission, so its broadcast preflight cannot race another
  sender into a partially admitted broadcast.

  Pending content remains in this process's mailbox. The receive loop selects
  control requests without consuming those envelopes until attachment; state
  holds only their count and byte total. Attached delivery and the pending flush
  share this sender, preserving FIFO without awaiting session acknowledgements.
  Callers await those acknowledgements outside both owners.

  This process monitors its coordinator and is monitored by it. It never restarts
  or replays content after either owner dies, and needs no application-wide inbox
  registry or supervisor. Admission failure is not retried automatically.
  """

  alias CodingAgent.Session

  @max_count 64
  @max_bytes 256 * 1024

  @doc false
  def start do
    owner = self()

    spawn_monitor(fn ->
      loop(%{owner: owner, monitor: Process.monitor(owner), session: nil, count: 0, bytes: 0})
    end)
  end

  @doc false
  def capacity(inbox, text), do: call(inbox, {:capacity, text})

  @doc false
  def deliver(inbox, text, reply_to), do: call(inbox, {:deliver, text, reply_to})

  @doc false
  def attach(inbox, session, reply_to), do: call(inbox, {:attach, session, reply_to})

  @doc false
  def detach(nil), do: :ok
  def detach(inbox), do: call(inbox, :detach)

  @doc false
  def stop(nil), do: :ok
  def stop(inbox), do: call(inbox, :stop)

  defp call(inbox, request) when is_pid(inbox) do
    GenServer.call(inbox, request)
  catch
    :exit, _ -> {:error, "Task inbox is unavailable"}
  end

  defp call(_inbox, _request), do: {:error, "Task inbox is unavailable"}

  defp loop(%{owner: owner, monitor: monitor} = state) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok

      {:"$gen_call", {^owner, _tag} = from, :stop} ->
        GenServer.reply(from, :ok)

      {:"$gen_call", {^owner, _tag} = from, request} ->
        {reply, state} = handle(request, state)
        GenServer.reply(from, reply)
        loop(state)

      {:"$gen_call", from, _request} ->
        GenServer.reply(from, {:error, "Task inbox owner mismatch"})
        loop(state)
    end
  end

  defp handle({:capacity, text}, state), do: {capacity_for(state, text), state}

  defp handle({:deliver, text, reply_to}, %{session: session} = state) when is_pid(session) do
    {{:delivery, Session.request_steering(session, text, reply_to)}, state}
  end

  defp handle({:deliver, text, _reply_to}, state) do
    case capacity_for(state, text) do
      :ok ->
        send(self(), {:task_message, text})
        {:ok, %{state | count: state.count + 1, bytes: state.bytes + byte_size(text)}}

      error ->
        {error, state}
    end
  end

  defp handle({:attach, session, reply_to}, state) do
    deliveries = drain(state.count, &Session.request_steering(session, &1, reply_to))
    {{:deliver_pending, deliveries}, %{state | session: session, count: 0, bytes: 0}}
  end

  defp handle(:detach, state) do
    drain(state.count, fn _text -> :ok end)
    {:ok, %{state | session: nil, count: 0, bytes: 0}}
  end

  defp capacity_for(%{session: session}, _text) when is_pid(session), do: :ok

  defp capacity_for(state, text) do
    if state.count >= @max_count or state.bytes + byte_size(text) > @max_bytes,
      do: {:error, "Task message queue is full (64 messages / 256 KiB)"},
      else: :ok
  end

  defp drain(0, _deliver), do: []

  defp drain(count, deliver) do
    receive do
      {:task_message, text} -> [deliver.(text) | drain(count - 1, deliver)]
    end
  end
end
