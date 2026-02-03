defmodule LemonGateway.Telegram.Outbox do
  @moduledoc false
  use GenServer

  alias LemonGateway.Telegram.API
  alias LemonGateway.Telegram.Truncate

  @default_edit_throttle 400

  def start_link(opts) do
    config =
      Application.get_env(:lemon_gateway, :telegram, %{})
      |> merge_config(opts)

    token = config[:bot_token] || config["bot_token"]

    if is_binary(token) and token != "" do
      GenServer.start_link(__MODULE__, config, name: __MODULE__)
    else
      :ignore
    end
  end

  @spec enqueue(term(), integer(), term()) :: :ok
  def enqueue(key, _priority, op) do
    GenServer.cast(__MODULE__, {:enqueue, key, op})
  end

  @impl true
  def init(config) do
    state = %{
      token: config[:bot_token] || config["bot_token"],
      api_mod: config[:api_mod] || API,
      edit_throttle_ms: config[:edit_throttle_ms] || @default_edit_throttle,
      queue: :queue.new(),
      ops: %{},
      next_at: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, key, op}, state) do
    if state.edit_throttle_ms == 0 do
      execute_op(state, op)
      {:noreply, state}
    else
      {queue, ops} =
        if Map.has_key?(state.ops, key) do
          {state.queue, Map.put(state.ops, key, op)}
        else
          {:queue.in(key, state.queue), Map.put(state.ops, key, op)}
        end

      state = %{state | queue: queue, ops: ops}
      state = schedule_drain(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:drain, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      :queue.is_empty(state.queue) ->
        {:noreply, %{state | next_at: 0}}

      now < state.next_at ->
        Process.send_after(self(), :drain, state.next_at - now)
        {:noreply, state}

      true ->
        {{:value, key}, queue} = :queue.out(state.queue)
        {op, ops} = Map.pop(state.ops, key)
        state = %{state | queue: queue, ops: ops}

        execute_op(state, op)

        next_at = now + state.edit_throttle_ms
        state = %{state | next_at: next_at}
        Process.send_after(self(), :drain, state.edit_throttle_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_drain(state) do
    if state.next_at == 0 do
      send(self(), :drain)
      state
    else
      state
    end
  end

  defp execute_op(state, {:edit, chat_id, message_id, %{text: text} = payload}) do
    engine = payload[:engine]
    truncated_text = truncate_text(text, engine)
    _ = state.api_mod.edit_message_text(state.token, chat_id, message_id, truncated_text)
    :ok
  end

  defp execute_op(state, {:send, chat_id, payload}) do
    text = payload[:text] || payload["text"] || ""
    engine = payload[:engine]
    reply_to = payload[:reply_to_message_id] || payload["reply_to_message_id"]
    truncated_text = truncate_text(text, engine)
    _ = state.api_mod.send_message(state.token, chat_id, truncated_text, reply_to)
    :ok
  end

  defp truncate_text(text, nil) do
    # No engine specified, use generic truncation
    Truncate.truncate_for_telegram(text)
  end

  defp truncate_text(text, engine_module) when is_atom(engine_module) do
    Truncate.truncate_for_telegram(text, engine_module)
  end

  defp truncate_text(text, _) do
    Truncate.truncate_for_telegram(text)
  end

  defp merge_config(config, opts) when is_list(opts) do
    Enum.reduce(opts, config, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp merge_config(config, _opts), do: config
end
