defmodule LemonChannels.Telegram.TriggerMode do
  @moduledoc false

  alias LemonCore.Store
  alias LemonCore.ChatScope

  @chat_table :telegram_chat_trigger_mode
  @topic_table :telegram_topic_trigger_mode
  # Groups only wake the agent when addressed (mention, reply, or command),
  # matching Discord; `/trigger all` opts a chat or topic into every message.
  @default_mode :mentions

  @spec resolve(String.t(), integer(), integer() | nil) :: %{
          mode: :all | :mentions,
          chat_mode: :all | :mentions | :unavailable | nil,
          topic_mode: :all | :mentions | :unavailable | nil,
          source: :default | :chat | :topic | :unavailable
        }
  def resolve(account_id, chat_id, topic_id \\ nil)

  # Layers are read strictly. A layer that cannot be read never falls through
  # to a broader one: the result is `:mentions` with `source: :unavailable`.
  # Every configurable mode admits addressed messages, so `:mentions` is the
  # narrowest admission any configuration could produce.
  def resolve(account_id, chat_id, topic_id)
      when is_binary(account_id) and is_integer(chat_id) do
    topic =
      if is_integer(topic_id),
        do: fetch_mode(@topic_table, {account_id, chat_id, topic_id}),
        else: {:ok, nil}

    chat = fetch_mode(@chat_table, {account_id, chat_id})

    {mode, source} =
      case {topic, chat} do
        {{:ok, topic_mode}, _chat} when not is_nil(topic_mode) -> {topic_mode, :topic}
        {{:ok, nil}, {:ok, chat_mode}} when not is_nil(chat_mode) -> {chat_mode, :chat}
        {{:ok, nil}, {:ok, nil}} -> {@default_mode, :default}
        _unavailable -> {@default_mode, :unavailable}
      end

    %{
      mode: mode,
      chat_mode: layer(chat),
      topic_mode: layer(topic),
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

  defp fetch_mode(table, key) do
    case Store.fetch(table, key) do
      {:ok, %{mode: mode}} when mode in [:all, :mentions] -> {:ok, mode}
      {:ok, mode} when mode in [:all, :mentions] -> {:ok, mode}
      {:ok, _none} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp layer({:ok, mode}), do: mode
  defp layer({:error, _reason}), do: :unavailable

  defp set_chat_mode(account_id, chat_id, mode) do
    Store.put(@chat_table, {account_id, chat_id}, %{mode: mode, updated_at: now_ms()})
  end

  defp set_topic_mode(account_id, chat_id, topic_id, mode) do
    Store.put(@topic_table, {account_id, chat_id, topic_id}, %{mode: mode, updated_at: now_ms()})
  end

  defp now_ms, do: System.system_time(:millisecond)
end
