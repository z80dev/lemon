defmodule LemonGateway.TestSupport.MockTelegramAPI do
  @moduledoc false

  # A test double for `LemonGateway.Telegram.API`.
  #
  # It implements:
  # - `get_updates/3` (for polling transports)
  # - `send_message/5`, `edit_message_text/5`, `delete_message/3` (for outbound delivery)
  #
  # All calls are recorded and can be asserted in integration tests.

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          calls: [],
          pending_updates: opts[:updates] || [],
          update_id: opts[:start_update_id] || 1000,
          notify_pid: opts[:notify_pid]
        }
      end,
      name: __MODULE__
    )
  end

  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.stop(pid, :normal, 100)
    end
  catch
    :exit, _ -> :ok
  end

  def reset!(opts \\ []) do
    stop()
    {:ok, _} = start_link(opts)
    :ok
  end

  def set_notify_pid(pid) when is_pid(pid) do
    Agent.update(__MODULE__, &%{&1 | notify_pid: pid})
  end

  def enqueue_update(update) when is_map(update) do
    Agent.update(__MODULE__, fn state ->
      id = state.update_id
      update_with_id = Map.put(update, "update_id", id)
      %{state | pending_updates: state.pending_updates ++ [update_with_id], update_id: id + 1}
    end)
  end

  def enqueue_message(chat_id, text, opts \\ []) when is_integer(chat_id) and is_binary(text) do
    message_id = Keyword.get(opts, :message_id, System.unique_integer([:positive]))
    topic_id = Keyword.get(opts, :topic_id)
    reply_to = Keyword.get(opts, :reply_to)

    message = %{
      "message_id" => message_id,
      "chat" => %{"id" => chat_id, "type" => "private"},
      "text" => text,
      "date" => System.system_time(:second)
    }

    message =
      if topic_id do
        Map.put(message, "message_thread_id", topic_id)
      else
        message
      end

    message =
      if reply_to do
        Map.put(message, "reply_to_message", %{"message_id" => reply_to, "text" => ""})
      else
        message
      end

    enqueue_update(%{"message" => message})
  end

  def calls do
    Agent.get(__MODULE__, fn state -> Enum.reverse(state.calls) end)
  end

  # Telegram API surface

  def get_updates(_token, _offset, _timeout_ms) do
    Agent.get_and_update(__MODULE__, fn state ->
      updates = state.pending_updates
      notify_pid = state.notify_pid
      if is_pid(notify_pid), do: send(notify_pid, {:telegram_get_updates, updates})
      new_state = %{state | pending_updates: []}
      {{:ok, %{"ok" => true, "result" => updates}}, new_state}
    end)
  end

  def send_message(_token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil) do
    record({:send_message, chat_id, text, reply_to_or_opts, parse_mode})
    msg_id = System.unique_integer([:positive])
    {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}}
  end

  def edit_message_text(_token, chat_id, message_id, text, parse_mode_or_opts \\ nil) do
    record({:edit_message, chat_id, message_id, text, parse_mode_or_opts})
    {:ok, %{"ok" => true}}
  end

  def delete_message(_token, chat_id, message_id) do
    record({:delete_message, chat_id, message_id})
    {:ok, %{"ok" => true}}
  end

  def set_message_reaction(_token, chat_id, message_id, emoji, _opts \\ %{}) do
    record({:set_message_reaction, chat_id, message_id, emoji})
    {:ok, %{"ok" => true}}
  end

  defp record(call) do
    Agent.update(__MODULE__, fn state ->
      %{state | calls: [call | state.calls]}
    end)

    notify_pid = Agent.get(__MODULE__, & &1.notify_pid)
    if is_pid(notify_pid), do: send(notify_pid, {:telegram_api_call, call})
    :ok
  end
end
