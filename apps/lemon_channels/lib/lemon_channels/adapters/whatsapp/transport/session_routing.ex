defmodule LemonChannels.Adapters.WhatsApp.Transport.SessionRouting do
  @moduledoc false

  require Logger

  alias LemonChannels.BindingResolver
  alias LemonCore.ChatScope
  alias LemonCore.SessionKey

  @spec build_session_key(binary() | nil, map(), ChatScope.t()) :: binary()
  def build_session_key(account_id, inbound, %ChatScope{} = scope) do
    agent_id =
      inbound.meta[:agent_id] ||
        (inbound.meta && inbound.meta["agent_id"]) ||
        BindingResolver.resolve_agent_id(scope) ||
        "default"

    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: "whatsapp",
      account_id: account_id || "default",
      peer_kind: inbound.peer.kind || :unknown,
      peer_id: to_string(scope.chat_id),
      thread_id: inbound.peer.thread_id
    })
  end

  @spec maybe_mark_new_session_pending(map(), binary() | nil, binary() | nil, map()) :: map()
  def maybe_mark_new_session_pending(pending_new, peer_id, thread_id, inbound) do
    if pending_new_for_scope?(pending_new, peer_id, thread_id) do
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

  @spec maybe_mark_fork_when_busy(binary() | nil, map(), binary() | nil, binary() | nil) :: map()
  def maybe_mark_fork_when_busy(account_id, inbound, peer_id, thread_id) do
    reply_to_id = inbound.message.reply_to_id || inbound.meta[:reply_to_id]

    cond do
      not is_nil(reply_to_id) ->
        inbound

      is_binary(peer_id) and peer_id != "" ->
        scope = %ChatScope{transport: :whatsapp, chat_id: peer_id, topic_id: thread_id}
        base_session_key = build_session_key(account_id, inbound, scope)

        if is_binary(base_session_key) and session_busy?(base_session_key) do
          Logger.warning(
            "WhatsApp auto-forking busy session peer_id=#{inspect(peer_id)} thread_id=#{inspect(thread_id)} " <>
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
  def resolve_session_key(account_id, inbound, %ChatScope{} = scope, meta0, _generation) do
    meta = meta0 || %{}
    explicit = extract_explicit_session_key(meta)
    base_session_key = build_session_key(account_id, inbound, scope)

    session_key =
      cond do
        is_binary(explicit) and explicit != "" ->
          explicit

        (meta[:fork_when_busy] == true or meta["fork_when_busy"] == true) and
            is_binary(meta[:user_msg_id] || meta["user_msg_id"]) ->
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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp pending_new_for_scope?(pending_new, peer_id, thread_id)
       when is_binary(peer_id) and is_map(pending_new) do
    pending_new
    |> Map.values()
    |> Enum.any?(fn pending ->
      pending_peer_id = pending[:peer_id] || pending["peer_id"]
      pending_thread_id = pending[:thread_id] || pending["thread_id"]
      pending_peer_id == peer_id and pending_thread_id == thread_id
    end)
  rescue
    _ -> false
  end

  defp pending_new_for_scope?(_pending_new, _peer_id, _thread_id), do: false

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
