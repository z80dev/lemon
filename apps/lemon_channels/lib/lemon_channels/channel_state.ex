defmodule LemonChannels.ChannelState do
  @moduledoc """
  Abstract API for channel-specific persistent state.

  Provides a boundary between the router layer and Telegram-specific state
  stored in `LemonCore.Store`. The router should use this module instead of
  directly accessing `:telegram_*` Store tables.

  ## Supported State Keys

  - `:telegram_pending_compaction` — marks threads needing compaction
  - `:telegram_msg_resume` — maps message IDs to resume tokens
  - `:telegram_selected_resume` — currently selected resume token per thread
  - `:telegram_msg_session` — maps message IDs to session keys

  ## Session Key Parsing

  Several functions accept a `session_key` string and extract Telegram routing
  coordinates (account_id, chat_id, thread_id) from it. Non-Telegram session
  keys are silently ignored (`:ok` is returned).
  """

  require Logger

  alias LemonCore.ResumeToken

  # ── Compaction ──────────────────────────────────────────────────────────

  @doc """
  Mark a Telegram thread as needing compaction.

  Parses the session key to extract Telegram routing coordinates.
  Non-Telegram session keys are silently ignored.

  `reason` is a string or atom describing why compaction is needed
  (e.g., `:overflow`, `:near_limit`).

  `details` is an optional map of additional metadata to merge into the
  compaction marker (e.g., `%{input_tokens: 950, threshold_tokens: 900}`).
  """
  @spec mark_pending_compaction(String.t(), atom() | String.t(), map()) :: :ok
  def mark_pending_compaction(session_key, reason, details \\ %{})

  def mark_pending_compaction(session_key, reason, details)
      when is_binary(session_key) and is_map(details) do
    with {:ok, coords} <- parse_telegram_coords(session_key),
         true <- is_integer(coords.chat_id) do
      payload =
        %{
          reason: to_string(reason || "unknown"),
          session_key: session_key,
          set_at_ms: System.system_time(:millisecond)
        }
        |> Map.merge(compaction_marker_details(details))

      LemonCore.Store.put(
        :telegram_pending_compaction,
        {coords.account_id, coords.chat_id, coords.thread_id},
        payload
      )
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def mark_pending_compaction(_session_key, _reason, _details), do: :ok

  @doc """
  Read a pending compaction marker for the given Telegram thread coordinates.

  Returns the compaction marker map if present, or `nil`.
  """
  @spec get_pending_compaction(String.t(), integer(), integer() | nil) :: map() | nil
  def get_pending_compaction(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.get(:telegram_pending_compaction, {account_id, chat_id, thread_id})
  rescue
    _ -> nil
  end

  def get_pending_compaction(_account_id, _chat_id, _thread_id), do: nil

  @doc """
  Delete a pending compaction marker for the given Telegram thread coordinates.
  """
  @spec delete_pending_compaction(String.t(), integer(), integer() | nil) :: :ok
  def delete_pending_compaction(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.delete(:telegram_pending_compaction, {account_id, chat_id, thread_id})
    :ok
  rescue
    _ -> :ok
  end

  def delete_pending_compaction(_account_id, _chat_id, _thread_id), do: :ok

  # ── Resume State ────────────────────────────────────────────────────────

  @doc """
  Reset all Telegram resume state for a session.

  Parses the session key, and if it is a Telegram session, deletes:
  - the selected resume token for the thread
  - all `:telegram_msg_session` index entries for the thread
  - all `:telegram_msg_resume` index entries for the thread

  Non-Telegram session keys are silently ignored.
  """
  @spec reset_resume_state(String.t()) :: :ok
  def reset_resume_state(session_key) when is_binary(session_key) do
    with {:ok, coords} <- parse_telegram_coords(session_key),
         true <- is_integer(coords.chat_id) do
      _ = safe_delete_selected_resume(coords.account_id, coords.chat_id, coords.thread_id)
      _ = safe_clear_thread_index(:telegram_msg_session, coords.account_id, coords.chat_id, coords.thread_id)
      _ = safe_clear_thread_index(:telegram_msg_resume, coords.account_id, coords.chat_id, coords.thread_id)

      Logger.warning(
        "Reset Telegram resume state for session_key=#{inspect(session_key)}"
      )
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def reset_resume_state(_), do: :ok

  @doc """
  Store a resume token indexed by message ID.

  The key is `{account_id, chat_id, thread_id, message_id}`.
  """
  @spec put_resume(String.t(), integer(), integer() | nil, integer(), ResumeToken.t()) :: :ok
  def put_resume(account_id, chat_id, thread_id, message_id, resume)
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) do
    key = {account_id, chat_id, thread_id, message_id}
    LemonCore.Store.put(:telegram_msg_resume, key, resume)
    :ok
  rescue
    _ -> :ok
  end

  def put_resume(_account_id, _chat_id, _thread_id, _message_id, _resume), do: :ok

  @doc """
  Look up a resume token by message ID.
  """
  @spec get_resume(String.t(), integer(), integer() | nil, integer()) :: ResumeToken.t() | nil
  def get_resume(account_id, chat_id, thread_id, message_id)
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) do
    key = {account_id, chat_id, thread_id, message_id}
    LemonCore.Store.get(:telegram_msg_resume, key)
  rescue
    _ -> nil
  end

  def get_resume(_account_id, _chat_id, _thread_id, _message_id), do: nil

  @doc """
  Store a resume token indexed by message ID with a generation.

  The key is `{account_id, chat_id, thread_id, generation, message_id}`.
  """
  @spec put_resume_with_generation(String.t(), integer(), integer() | nil, non_neg_integer(), integer(), ResumeToken.t()) ::
          :ok
  def put_resume_with_generation(account_id, chat_id, thread_id, generation, message_id, resume)
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) and
             is_integer(generation) do
    key = {account_id, chat_id, thread_id, generation, message_id}
    LemonCore.Store.put(:telegram_msg_resume, key, resume)
    :ok
  rescue
    _ -> :ok
  end

  def put_resume_with_generation(_account_id, _chat_id, _thread_id, _generation, _message_id, _resume),
    do: :ok

  @doc """
  Look up a resume token by message ID with a generation.

  Returns the resume token for the given generation key, or falls back to
  the legacy (no-generation) key when `generation == 0`.
  """
  @spec get_resume_with_generation(String.t(), integer(), integer() | nil, non_neg_integer(), integer()) ::
          ResumeToken.t() | nil
  def get_resume_with_generation(account_id, chat_id, thread_id, generation, message_id)
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) and
             is_integer(generation) do
    key = {account_id, chat_id, thread_id, generation, message_id}

    case LemonCore.Store.get(:telegram_msg_resume, key) do
      %ResumeToken{} = tok ->
        tok

      _ when generation == 0 ->
        legacy_key = {account_id, chat_id, thread_id, message_id}
        LemonCore.Store.get(:telegram_msg_resume, legacy_key)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def get_resume_with_generation(_account_id, _chat_id, _thread_id, _generation, _message_id),
    do: nil

  # ── Selected Resume ─────────────────────────────────────────────────────

  @doc """
  Store the currently selected resume token for a Telegram thread.
  """
  @spec put_selected_resume(String.t(), integer(), integer() | nil, ResumeToken.t()) :: :ok
  def put_selected_resume(account_id, chat_id, thread_id, resume)
      when is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.put(
      :telegram_selected_resume,
      {account_id, chat_id, thread_id},
      resume
    )

    :ok
  rescue
    _ -> :ok
  end

  def put_selected_resume(_account_id, _chat_id, _thread_id, _resume), do: :ok

  @doc """
  Get the currently selected resume token for a Telegram thread.
  """
  @spec get_selected_resume(String.t(), integer(), integer() | nil) :: ResumeToken.t() | nil
  def get_selected_resume(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.get(:telegram_selected_resume, {account_id, chat_id, thread_id})
  rescue
    _ -> nil
  end

  def get_selected_resume(_account_id, _chat_id, _thread_id), do: nil

  @doc """
  Delete the currently selected resume token for a Telegram thread.
  """
  @spec delete_selected_resume(String.t(), integer(), integer() | nil) :: :ok
  def delete_selected_resume(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.delete(:telegram_selected_resume, {account_id, chat_id, thread_id})
    :ok
  rescue
    _ -> :ok
  end

  def delete_selected_resume(_account_id, _chat_id, _thread_id), do: :ok

  # ── Message Session Index ───────────────────────────────────────────────

  @doc """
  Store a message-to-session mapping with a generation.
  """
  @spec put_msg_session(String.t(), integer(), integer() | nil, non_neg_integer(), integer(), String.t()) ::
          :ok
  def put_msg_session(account_id, chat_id, thread_id, generation, message_id, session_key)
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) and
             is_integer(generation) and is_binary(session_key) do
    key = {account_id, chat_id, thread_id, generation, message_id}
    LemonCore.Store.put(:telegram_msg_session, key, session_key)
    :ok
  rescue
    _ -> :ok
  end

  def put_msg_session(_account_id, _chat_id, _thread_id, _generation, _message_id, _session_key),
    do: :ok

  @doc """
  Look up a session key by message ID with a generation.

  Falls back to the legacy (no-generation) key when `generation == 0`.
  """
  @spec get_msg_session(String.t(), integer(), integer() | nil, non_neg_integer(), integer()) ::
          String.t() | nil
  def get_msg_session(account_id, chat_id, thread_id, generation, message_id)
      when is_binary(account_id) and is_integer(chat_id) and is_integer(message_id) and
             is_integer(generation) do
    key = {account_id, chat_id, thread_id, generation, message_id}

    case LemonCore.Store.get(:telegram_msg_session, key) do
      sk when is_binary(sk) and sk != "" ->
        sk

      _ when generation == 0 ->
        legacy_key = {account_id, chat_id, thread_id, message_id}

        case LemonCore.Store.get(:telegram_msg_session, legacy_key) do
          sk when is_binary(sk) and sk != "" -> sk
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def get_msg_session(_account_id, _chat_id, _thread_id, _generation, _message_id), do: nil

  # ── Private Helpers ─────────────────────────────────────────────────────

  defp parse_telegram_coords(session_key) when is_binary(session_key) do
    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :channel_peer, channel_id: "telegram"} = parsed ->
        account_id =
          case parsed.account_id do
            account when is_binary(account) and account != "" -> account
            _ -> "default"
          end

        chat_id = parse_int(parsed.peer_id)
        thread_id = parse_int(parsed.thread_id)

        {:ok, %{account_id: account_id, chat_id: chat_id, thread_id: thread_id}}

      _ ->
        :not_telegram
    end
  rescue
    _ -> :error
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp safe_delete_selected_resume(account_id, chat_id, thread_id)
       when is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.delete(:telegram_selected_resume, {account_id, chat_id, thread_id})
    :ok
  rescue
    _ -> :ok
  end

  defp safe_delete_selected_resume(_account_id, _chat_id, _thread_id), do: :ok

  defp safe_clear_thread_index(table, account_id, chat_id, thread_id)
       when is_atom(table) and is_binary(account_id) and is_integer(chat_id) do
    LemonCore.Store.list(table)
    |> Enum.each(fn
      {{acc, cid, tid, _gen, _msg_id} = key, _value}
      when acc == account_id and cid == chat_id and tid == thread_id ->
        _ = LemonCore.Store.delete(table, key)

      {{acc, cid, tid, _msg_id} = key, _value}
      when acc == account_id and cid == chat_id and tid == thread_id ->
        _ = LemonCore.Store.delete(table, key)

      _ ->
        :ok
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp safe_clear_thread_index(_table, _account_id, _chat_id, _thread_id), do: :ok

  defp compaction_marker_details(details) when is_map(details) do
    Enum.reduce(details, %{}, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc when is_atom(key) or is_binary(key) ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  defp compaction_marker_details(_), do: %{}
end
