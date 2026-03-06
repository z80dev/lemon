defmodule LemonChannels.Adapters.Telegram.Transport.SessionRouting do
  @moduledoc false

  require Logger

  alias LemonChannels.BindingResolver
  alias LemonChannels.Telegram.ResumeIndexStore
  alias LemonCore.ChatScope
  alias LemonCore.SessionKey

  @spec normalize_msg_id(term()) :: integer() | nil
  def normalize_msg_id(nil), do: nil
  def normalize_msg_id(i) when is_integer(i), do: i

  def normalize_msg_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  def normalize_msg_id(_), do: nil

  @spec build_session_key(binary() | nil, map(), ChatScope.t()) :: binary()
  def build_session_key(account_id, inbound, %ChatScope{} = scope) do
    agent_id =
      inbound.meta[:agent_id] ||
        (inbound.meta && inbound.meta["agent_id"]) ||
        BindingResolver.resolve_agent_id(scope) ||
        "default"

    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: "telegram",
      account_id: account_id || "default",
      peer_kind: inbound.peer.kind || :unknown,
      peer_id: to_string(scope.chat_id),
      thread_id: inbound.peer.thread_id
    })
  end

  @spec maybe_mark_new_session_pending(map(), integer() | nil, integer() | nil, map()) :: map()
  def maybe_mark_new_session_pending(pending_new, chat_id, thread_id, inbound) do
    if pending_new_for_scope?(pending_new, chat_id, thread_id) do
      meta =
        (inbound.meta || %{})
        |> Map.put(:new_session_pending, true)
        |> Map.put(:disable_auto_resume, true)

      %{inbound | meta: meta}
    else
      inbound
    end
  rescue
    _ -> inbound
  end

  @spec maybe_mark_fork_when_busy(binary() | nil, map(), integer() | nil, integer() | nil) ::
          map()
  def maybe_mark_fork_when_busy(account_id, inbound, chat_id, thread_id) do
    reply_to_id = normalize_msg_id(inbound.message.reply_to_id || inbound.meta[:reply_to_id])

    cond do
      is_integer(reply_to_id) ->
        inbound

      is_integer(chat_id) ->
        scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
        base_session_key = build_session_key(account_id, inbound, scope)

        if is_binary(base_session_key) and session_busy?(base_session_key) do
          Logger.warning(
            "Telegram auto-forking busy session chat_id=#{inspect(chat_id)} thread_id=#{inspect(thread_id)} " <>
              "base_session_key=#{inspect(base_session_key)} user_msg_id=#{inspect(inbound.meta[:user_msg_id])}"
          )

          %{inbound | meta: Map.put(inbound.meta || %{}, :fork_when_busy, true)}
        else
          inbound
        end

      true ->
        inbound
    end
  rescue
    _ -> inbound
  end

  @spec resolve_session_key(binary() | nil, map(), ChatScope.t(), map(), non_neg_integer()) ::
          {binary() | nil, boolean()}
  def resolve_session_key(account_id, inbound, %ChatScope{} = scope, meta0, generation) do
    meta = meta0 || %{}
    explicit = extract_explicit_session_key(meta)
    base_session_key = build_session_key(account_id, inbound, scope)

    reply_to_id =
      normalize_msg_id(inbound.message.reply_to_id || meta[:reply_to_id] || meta["reply_to_id"])

    session_key =
      cond do
        is_binary(explicit) and explicit != "" ->
          explicit

        is_integer(reply_to_id) ->
          lookup_session_key_for_reply(account_id, scope, reply_to_id, generation) ||
            base_session_key

        (meta[:fork_when_busy] == true or meta["fork_when_busy"] == true) and
            is_integer(meta[:user_msg_id] || meta["user_msg_id"]) ->
          maybe_with_sub_id(base_session_key, meta[:user_msg_id] || meta["user_msg_id"])

        true ->
          base_session_key
      end

    {session_key, is_binary(session_key) and session_key != base_session_key}
  rescue
    _ ->
      base_session_key = build_session_key(account_id, inbound, scope)
      {base_session_key, false}
  end

  def resolve_session_key(_account_id, _inbound, _scope, meta0, _generation) do
    {extract_explicit_session_key(meta0 || %{}), false}
  end

  @spec lookup_session_key_for_reply(binary() | nil, ChatScope.t(), integer(), non_neg_integer()) ::
          binary() | nil
  def lookup_session_key_for_reply(account_id, %ChatScope{} = scope, reply_to_id, generation)
      when is_integer(reply_to_id) do
    case ResumeIndexStore.get_session(
           account_id || "default",
           scope.chat_id,
           scope.topic_id,
           reply_to_id,
           generation: generation
         ) do
      sk when is_binary(sk) and sk != "" -> sk
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @spec maybe_index_telegram_msg_session(
          binary() | nil,
          ChatScope.t(),
          binary(),
          list(),
          non_neg_integer()
        ) ::
          :ok
  def maybe_index_telegram_msg_session(
        account_id,
        %ChatScope{} = scope,
        session_key,
        msg_ids,
        generation
      )
      when is_list(msg_ids) and is_binary(session_key) and session_key != "" do
    msg_ids
    |> Enum.map(&normalize_msg_id/1)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.each(fn msg_id ->
      _ =
        ResumeIndexStore.put_session(
          account_id || "default",
          scope.chat_id,
          scope.topic_id,
          msg_id,
          session_key,
          generation: generation
        )
    end)

    :ok
  rescue
    _ -> :ok
  end

  def maybe_index_telegram_msg_session(_account_id, _scope, _session_key, _msg_ids, _generation),
    do: :ok

  defp pending_new_for_scope?(pending_new, chat_id, thread_id)
       when is_integer(chat_id) and is_map(pending_new) do
    pending_new
    |> Map.values()
    |> Enum.any?(fn pending ->
      pending_chat_id = pending[:chat_id] || pending["chat_id"]
      pending_thread_id = pending[:thread_id] || pending["thread_id"]
      pending_chat_id == chat_id and pending_thread_id == thread_id
    end)
  rescue
    _ -> false
  end

  defp pending_new_for_scope?(_pending_new, _chat_id, _thread_id), do: false

  defp session_busy?(session_key) when is_binary(session_key) and session_key != "" do
    LemonChannels.Runtime.session_busy?(session_key)
  rescue
    _ -> false
  end

  defp session_busy?(_), do: false

  defp extract_explicit_session_key(meta) when is_map(meta) do
    candidate =
      cond do
        is_binary(meta[:session_key]) and meta[:session_key] != "" -> meta[:session_key]
        is_binary(meta["session_key"]) and meta["session_key"] != "" -> meta["session_key"]
        true -> nil
      end

    if is_binary(candidate) and SessionKey.valid?(candidate), do: candidate, else: nil
  end

  defp extract_explicit_session_key(_), do: nil

  defp maybe_with_sub_id(session_key, sub_id)
       when is_binary(session_key) and session_key != "" and
              (is_binary(sub_id) or is_integer(sub_id)) do
    if String.contains?(session_key, ":sub:") do
      session_key
    else
      session_key <> ":sub:" <> to_string(sub_id)
    end
  rescue
    _ -> session_key
  end

  defp maybe_with_sub_id(session_key, _sub_id), do: session_key
end
