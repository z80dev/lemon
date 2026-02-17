defmodule LemonChannels.Telegram.TriggerMode do
  @moduledoc false

  alias LemonCore.Store
  alias LemonChannels.Types.ChatScope

  @chat_table :telegram_chat_trigger_mode
  @topic_table :telegram_topic_trigger_mode
  @default_mode :all

  @spec resolve(String.t(), integer(), integer() | nil) :: %{
          mode: :all | :mentions,
          chat_mode: :all | :mentions | nil,
          topic_mode: :all | :mentions | nil,
          source: :default | :chat | :topic
        }
  def resolve(account_id, chat_id, topic_id \\ nil)

  def resolve(account_id, chat_id, topic_id)
      when is_binary(account_id) and is_integer(chat_id) do
    topic_mode =
      if is_integer(topic_id), do: get_topic_mode(account_id, chat_id, topic_id), else: nil

    chat_mode = get_chat_mode(account_id, chat_id)

    mode =
      cond do
        topic_mode in [:all, :mentions] -> topic_mode
        chat_mode in [:all, :mentions] -> chat_mode
        true -> @default_mode
      end

    source =
      cond do
        topic_mode in [:all, :mentions] -> :topic
        chat_mode in [:all, :mentions] -> :chat
        true -> :default
      end

    %{
      mode: mode,
      chat_mode: chat_mode,
      topic_mode: topic_mode,
      source: source
    }
  rescue
    _ -> %{mode: @default_mode, chat_mode: nil, topic_mode: nil, source: :default}
  end

  def resolve(_account_id, _chat_id, _topic_id),
    do: %{mode: @default_mode, chat_mode: nil, topic_mode: nil, source: :default}

  @spec set(ChatScope.t(), String.t(), :all | :mentions) :: :ok
  def set(%ChatScope{} = scope, account_id, mode)
      when mode in [:all, :mentions] and is_binary(account_id) do
    if is_integer(scope.topic_id) do
      set_topic_mode(account_id, scope.chat_id, scope.topic_id, mode)
    else
      set_chat_mode(account_id, scope.chat_id, mode)
    end
  end

  @spec clear_topic(String.t(), integer(), integer()) :: :ok
  def clear_topic(account_id, chat_id, topic_id)
      when is_binary(account_id) and is_integer(chat_id) and is_integer(topic_id) do
    Store.delete(@topic_table, {account_id, chat_id, topic_id})
  end

  defp get_chat_mode(account_id, chat_id) do
    case Store.get(@chat_table, {account_id, chat_id}) do
      %{mode: mode} when mode in [:all, :mentions] -> mode
      mode when mode in [:all, :mentions] -> mode
      _ -> nil
    end
  end

  defp get_topic_mode(account_id, chat_id, topic_id) do
    case Store.get(@topic_table, {account_id, chat_id, topic_id}) do
      %{mode: mode} when mode in [:all, :mentions] -> mode
      mode when mode in [:all, :mentions] -> mode
      _ -> nil
    end
  end

  defp set_chat_mode(account_id, chat_id, mode) do
    Store.put(@chat_table, {account_id, chat_id}, %{mode: mode, updated_at: now_ms()})
  end

  defp set_topic_mode(account_id, chat_id, topic_id, mode) do
    Store.put(@topic_table, {account_id, chat_id, topic_id}, %{mode: mode, updated_at: now_ms()})
  end

  defp now_ms, do: System.system_time(:millisecond)
end
