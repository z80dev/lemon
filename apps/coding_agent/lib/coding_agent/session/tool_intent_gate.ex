defmodule CodingAgent.Session.ToolIntentGate do
  @moduledoc false

  alias CodingAgent.SessionManager
  alias LemonAgent.AbortSignal

  # Caller policy: a dispatch may wait at most five seconds for its assistant
  # entry to traverse the event pipeline. Expiry refuses execution, never retries.
  @assistant_wait_ms 5_000

  def request(state, data, signal, parent_id, from) do
    cond do
      cancelled?(signal) ->
        {:reply, {:error, :cancelled}, state}

      state.is_streaming and is_nil(parent_id) and not assistant_recorded?(state, data) ->
        AbortSignal.subscribe(signal)
        monitor = Process.monitor(elem(from, 0))

        timer =
          Process.send_after(self(), {:tool_intent_wait_expired, monitor}, @assistant_wait_ms)

        pending = %{from: from, data: data, signal: signal, timer: timer}

        state = %{
          state
          | pending_tool_intents: Map.put(state.pending_tool_intents, monitor, pending)
        }

        if cancelled?(signal),
          do: {:noreply, cancel(state, monitor, :cancelled)},
          else: {:noreply, state}

      true ->
        {reply, state} = record(state, data)
        {:reply, reply, state}
    end
  end

  def flush(state) do
    Enum.reduce(state.pending_tool_intents, state, fn {ref, pending}, state ->
      cond do
        cancelled?(pending.signal) ->
          cancel(state, ref, :cancelled)

        assistant_recorded?(state, pending.data) ->
          state = remove(state, ref, pending)
          {reply, state} = record(state, pending.data)
          GenServer.reply(pending.from, reply)
          state

        true ->
          state
      end
    end)
  end

  def cancel_signal(state, signal) do
    Enum.reduce(state.pending_tool_intents, state, fn
      {ref, %{signal: ^signal}}, state -> cancel(state, ref, :cancelled)
      _, state -> state
    end)
  end

  def cancel(state, ref, reason) do
    case Map.fetch(state.pending_tool_intents, ref) do
      {:ok, pending} ->
        GenServer.reply(pending.from, {:error, reason})
        remove(state, ref, pending)

      :error ->
        state
    end
  end

  defp remove(state, ref, pending) do
    Process.cancel_timer(pending.timer)
    Process.demonitor(ref, [:flush])
    state = %{state | pending_tool_intents: Map.delete(state.pending_tool_intents, ref)}

    same_signal? =
      Enum.any?(state.pending_tool_intents, fn {_, p} -> p.signal == pending.signal end)

    wasm_waiter? =
      Enum.any?(Map.get(state, :wasm_host_calls, %{}), fn {_, call} ->
        Map.get(call, :parent_signal) == pending.signal
      end)

    unless same_signal? or wasm_waiter?, do: AbortSignal.unsubscribe(pending.signal)
    state
  end

  defp record(state, data) do
    file_module = Keyword.get(state.tool_opts, :tool_intent_file_module, :file)

    case SessionManager.record_tool_intent(state.session_manager, data, file_module) do
      {:ok, session} -> {:ok, %{state | session_manager: session}}
      {:error, reason, session} -> {{:error, reason}, %{state | session_manager: session}}
    end
  end

  defp assistant_recorded?(state, %{"toolCallId" => id}) do
    # The newest assistant entry owns the current batch; results/custom entries
    # can intervene, but older turns cannot authorize this invocation.
    case Enum.find(state.session_manager.entries_rev, fn entry ->
           entry.type == :message and entry.message["role"] == "assistant"
         end) do
      %{message: %{"content" => calls}} when is_list(calls) ->
        Enum.any?(calls, fn
          %{"type" => "tool_call", "id" => ^id} -> true
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp cancelled?(signal),
    do: AbortSignal.aborted?(signal) or AbortSignal.redirect_requested?(signal)
end
