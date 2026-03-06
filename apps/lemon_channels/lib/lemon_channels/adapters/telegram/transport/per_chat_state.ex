defmodule LemonChannels.Adapters.Telegram.Transport.PerChatState do
  @moduledoc false

  alias LemonChannels.Telegram.{ResumeIndexStore, StateStore}
  alias LemonCore.{ChatScope, ChatStateStore, ResumeToken, SessionKey}

  @spec safe_delete_chat_state(term()) :: :ok
  def safe_delete_chat_state(key) do
    ChatStateStore.delete(key)
    :ok
  rescue
    _ -> :ok
  end

  @spec safe_get_chat_state(term()) :: map() | nil
  def safe_get_chat_state(key) do
    ChatStateStore.get(key)
  rescue
    _ -> nil
  end

  @spec safe_delete_session_model(term()) :: :ok
  def safe_delete_session_model(session_key) when is_binary(session_key) do
    _ = StateStore.delete_session_model(session_key)
    :ok
  rescue
    _ -> :ok
  end

  def safe_delete_session_model(_session_key), do: :ok

  @spec safe_abort_session(term(), term()) :: :ok
  def safe_abort_session(session_key, reason)
      when is_binary(session_key) and byte_size(session_key) > 0 do
    _ = LemonCore.RouterBridge.abort_session(session_key, reason)
    :ok
  rescue
    _ -> :ok
  end

  def safe_abort_session(_, _), do: :ok

  @spec safe_delete_selected_resume(binary() | nil, integer(), integer() | nil) :: :ok
  def safe_delete_selected_resume(account_id, chat_id, thread_id) when is_integer(chat_id) do
    key = {account_id || "default", chat_id, thread_id}
    _ = StateStore.delete_selected_resume(key)
    :ok
  rescue
    _ -> :ok
  end

  def safe_delete_selected_resume(_account_id, _chat_id, _thread_id), do: :ok

  @spec safe_clear_thread_message_indices(binary() | nil, integer(), integer() | nil) :: :ok
  def safe_clear_thread_message_indices(account_id, chat_id, thread_id)
      when is_integer(chat_id) do
    _ = safe_sweep_thread_message_indices(account_id, chat_id, thread_id, :all)
    :ok
  rescue
    _ -> :ok
  end

  def safe_clear_thread_message_indices(_account_id, _chat_id, _thread_id), do: :ok

  @spec safe_sweep_thread_message_indices(binary() | nil, integer(), integer() | nil, term()) ::
          :ok
  def safe_sweep_thread_message_indices(account_id, chat_id, thread_id, max_generation)
      when is_integer(chat_id) do
    _ =
      ResumeIndexStore.delete_thread(account_id || "default", chat_id, thread_id,
        generation: max_generation
      )

    :ok
  rescue
    _ -> :ok
  end

  def safe_sweep_thread_message_indices(_account_id, _chat_id, _thread_id, _max_generation),
    do: :ok

  @spec current_thread_generation(binary() | nil, integer(), integer() | nil) :: non_neg_integer()
  def current_thread_generation(account_id, chat_id, thread_id) when is_integer(chat_id) do
    key = {account_id || "default", chat_id, thread_id}
    key |> StateStore.get_thread_generation() |> normalize_generation()
  rescue
    _ -> 0
  end

  def current_thread_generation(_account_id, _chat_id, _thread_id), do: 0

  @spec bump_thread_generation(binary() | nil, integer(), integer() | nil) ::
          {non_neg_integer(), non_neg_integer()}
  def bump_thread_generation(account_id, chat_id, thread_id) when is_integer(chat_id) do
    account_id = account_id || "default"
    key = {account_id, chat_id, thread_id}
    previous = current_thread_generation(account_id, chat_id, thread_id)
    next = previous + 1
    _ = StateStore.put_thread_generation(key, next)
    {previous, next}
  rescue
    _ -> {0, 0}
  end

  def bump_thread_generation(_account_id, _chat_id, _thread_id), do: {0, 0}

  @spec update_chat_state_last_engine(binary(), binary()) :: :ok
  def update_chat_state_last_engine(session_key, engine)
      when is_binary(session_key) and is_binary(engine) do
    now = System.system_time(:millisecond)
    existing = safe_get_chat_state(session_key)

    payload =
      case existing do
        %{last_resume_token: token} ->
          %{last_engine: engine, last_resume_token: token, updated_at: now}

        %{"last_resume_token" => token} ->
          %{last_engine: engine, last_resume_token: token, updated_at: now}

        _ ->
          %{last_engine: engine, updated_at: now}
      end

    ChatStateStore.put(session_key, payload)
    :ok
  rescue
    _ -> :ok
  end

  def update_chat_state_last_engine(_session_key, _engine), do: :ok

  @spec set_chat_resume(ChatScope.t(), binary(), ResumeToken.t()) :: :ok
  def set_chat_resume(%ChatScope{} = scope, session_key, %ResumeToken{} = resume)
      when is_binary(session_key) do
    now = System.system_time(:millisecond)

    ChatStateStore.put(session_key, %{
      last_engine: resume.engine,
      last_resume_token: resume.value,
      updated_at: now
    })

    account_id = state_account_id_from_session_key(session_key)
    _ = StateStore.put_selected_resume({account_id, scope.chat_id, scope.topic_id}, resume)
    :ok
  rescue
    _ -> :ok
  end

  @spec last_engine_hint(term()) :: binary() | nil
  def last_engine_hint(session_key) when is_binary(session_key) do
    state = safe_get_chat_state(session_key)
    engine = state && (state[:last_engine] || state["last_engine"] || state.last_engine)
    if is_binary(engine) and engine != "", do: engine, else: nil
  rescue
    _ -> nil
  end

  def last_engine_hint(_), do: nil

  @spec state_account_id_from_session_key(term()) :: binary()
  def state_account_id_from_session_key(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{account_id: account_id} when is_binary(account_id) -> account_id
      _ -> "default"
    end
  rescue
    _ -> "default"
  end

  def state_account_id_from_session_key(_), do: "default"

  @spec normalize_generation(term()) :: non_neg_integer()
  def normalize_generation(generation) when is_integer(generation) and generation >= 0,
    do: generation

  def normalize_generation(generation) when is_binary(generation) do
    case Integer.parse(generation) do
      {value, _} when value >= 0 -> value
      _ -> 0
    end
  end

  def normalize_generation(%{generation: generation}), do: normalize_generation(generation)
  def normalize_generation(%{"generation" => generation}), do: normalize_generation(generation)
  def normalize_generation(_generation), do: 0
end
