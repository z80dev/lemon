defmodule LemonChannels.Telegram.ResumeIndexStore do
  @moduledoc """
  Typed wrapper for Telegram message-id resume/session index tables.
  """

  alias LemonCore.ResumeToken
  alias LemonCore.Store
  alias LemonChannels.Telegram.StateStore

  @resume_table :telegram_msg_resume
  @session_table :telegram_msg_session

  @spec put_resume(binary(), integer(), integer() | nil, integer(), ResumeToken.t() | map(), keyword()) ::
          :ok
  def put_resume(account_id, chat_id, thread_id, message_id, resume, opts \\ [])
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) do
    Store.put(@resume_table, resume_key(account_id, chat_id, thread_id, message_id, opts), normalize_resume(resume))
  end

  @spec get_resume(binary(), integer(), integer() | nil, integer(), keyword()) ::
          ResumeToken.t() | map() | nil
  def get_resume(account_id, chat_id, thread_id, message_id, opts \\ [])
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) do
    generation = normalize_generation(Keyword.get(opts, :generation))

    case Store.get(@resume_table, {account_id, chat_id, thread_id, generation, message_id}) do
      nil when generation == 0 ->
        Store.get(@resume_table, {account_id, chat_id, thread_id, message_id})

      value ->
        value
    end
  end

  @spec put_session(binary(), integer(), integer() | nil, integer(), binary(), keyword()) :: :ok
  def put_session(account_id, chat_id, thread_id, message_id, session_key, opts \\ [])
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) and
             is_binary(session_key) do
    Store.put(@session_table, resume_key(account_id, chat_id, thread_id, message_id, opts), session_key)
  end

  @spec get_session(binary(), integer(), integer() | nil, integer(), keyword()) :: binary() | nil
  def get_session(account_id, chat_id, thread_id, message_id, opts \\ [])
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) do
    generation = normalize_generation(Keyword.get(opts, :generation))

    case Store.get(@session_table, {account_id, chat_id, thread_id, generation, message_id}) do
      nil when generation == 0 ->
        Store.get(@session_table, {account_id, chat_id, thread_id, message_id})

      value ->
        value
    end
  end

  @spec delete_thread(binary(), integer(), integer() | nil, keyword()) :: :ok
  def delete_thread(account_id, chat_id, thread_id, opts \\ [])
      when is_binary(account_id) and is_integer(chat_id) do
    max_generation =
      case Keyword.get(opts, :generation, :all) do
        :all -> :all
        value -> normalize_generation(value)
      end

    clear_table_thread(@resume_table, account_id, chat_id, thread_id, max_generation)
    clear_table_thread(@session_table, account_id, chat_id, thread_id, max_generation)
    :ok
  end

  defp clear_table_thread(table, account_id, chat_id, thread_id, max_generation) do
    table
    |> Store.list()
    |> Enum.each(fn
      {{acc, cid, tid, generation, _message_id} = key, _value}
      when acc == account_id and cid == chat_id and tid == thread_id ->
        if generation_match?(generation, max_generation), do: _ = Store.delete(table, key)

      {{acc, cid, tid, _message_id} = key, _value}
      when acc == account_id and cid == chat_id and tid == thread_id ->
        if generation_match?(0, max_generation), do: _ = Store.delete(table, key)

      _ ->
        :ok
    end)

    :ok
  end

  defp normalize_resume(%ResumeToken{} = resume), do: resume

  defp normalize_resume(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume(other), do: other

  defp resume_key(account_id, chat_id, thread_id, message_id, opts) do
    generation =
      opts
      |> Keyword.get(:generation, current_generation(account_id, chat_id, thread_id))
      |> normalize_generation()

    {account_id, chat_id, thread_id, generation, message_id}
  end

  defp current_generation(account_id, chat_id, thread_id) do
    StateStore.get_thread_generation({account_id, chat_id, thread_id}) |> normalize_generation()
  rescue
    _ -> 0
  end

  defp generation_match?(_generation, :all), do: true

  defp generation_match?(generation, max_generation) when is_integer(max_generation) do
    normalize_generation(generation) <= max_generation
  end

  defp generation_match?(_generation, _max_generation), do: false

  defp normalize_generation(generation) when is_integer(generation) and generation >= 0,
    do: generation

  defp normalize_generation(generation) when is_binary(generation) do
    case Integer.parse(generation) do
      {value, _} when value >= 0 -> value
      _ -> 0
    end
  end

  defp normalize_generation(%{generation: generation}), do: normalize_generation(generation)
  defp normalize_generation(%{"generation" => generation}), do: normalize_generation(generation)
  defp normalize_generation(_generation), do: 0
end
