defmodule LemonChannels.Adapters.Telegram.Transport.InboundActions do
  @moduledoc """
  Telegram-local execution helpers for normal inbound message submission.

  This module owns the side effects that happen after command/session routing
  decides a message should be submitted onward. It stays local to the Telegram
  transport and avoids introducing a shared cross-channel action framework.
  """

  require Logger

  alias LemonChannels.Adapters.Telegram.Transport.MessageBuffer
  alias LemonCore.ChatScope
  alias LemonCore.ResumeToken

  @model_default_engine "lemon"

  @type callbacks :: %{
          extract_explicit_resume_and_strip: (binary() -> {ResumeToken.t() | nil, binary()}),
          extract_message_ids: (map() -> {integer() | nil, integer() | nil, integer() | nil}),
          current_thread_generation: (map(), integer() | nil, integer() | nil ->
                                        integer() | nil),
          maybe_index_telegram_msg_session: (map(),
                                             ChatScope.t()
                                             | nil,
                                             binary()
                                             | nil,
                                             [integer() | nil] ->
                                               any()),
          maybe_subscribe_to_session: (binary() -> any()),
          resolve_model_hint: (map(), binary() | nil, integer() | nil, integer() | nil ->
                                 {binary() | nil, atom() | nil}),
          resolve_session_key: (map(), map(), ChatScope.t() | nil, map() ->
                                  {binary() | nil, boolean()}),
          resolve_thinking_hint: (map(), integer() | nil, integer() | nil ->
                                    {binary() | nil, atom() | nil}),
          update_chat_state_last_engine: (binary(), binary() -> any())
        }

  @spec submit_buffer(map(), map(), callbacks()) :: map()
  def submit_buffer(state, buffer, callbacks) when is_map(buffer) and is_map(callbacks) do
    buffer
    |> MessageBuffer.build_inbound()
    |> then(&execute_inbound_message(state, &1, callbacks))
  end

  def submit_buffer(state, _buffer, _callbacks), do: state

  @spec execute_inbound_message(map(), map(), callbacks()) :: map()
  def execute_inbound_message(state, inbound, callbacks)
      when is_map(inbound) and is_map(state) and is_map(callbacks) do
    {chat_id, thread_id, user_msg_id} = callbacks.extract_message_ids.(inbound)

    progress_msg_id =
      if is_integer(chat_id) and is_integer(user_msg_id) do
        send_progress(state, chat_id, user_msg_id)
      else
        nil
      end

    scope =
      if is_integer(chat_id) do
        %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      end

    meta0 =
      (inbound.meta || %{})
      |> Map.put(:progress_msg_id, progress_msg_id)
      |> Map.put(:user_msg_id, user_msg_id)
      |> Map.put(:status_msg_id, nil)
      |> Map.put(:topic_id, thread_id)
      |> Map.put(
        :thread_generation,
        callbacks.current_thread_generation.(state, chat_id, thread_id)
      )

    {session_key, forked?} = callbacks.resolve_session_key.(state, inbound, scope, meta0)

    Logger.debug(
      "Telegram submit inbound chat_id=#{inspect(chat_id)} thread_id=#{inspect(thread_id)} " <>
        "user_msg_id=#{inspect(user_msg_id)} session_key=#{inspect(session_key)} " <>
        "forked=#{inspect(forked?)} progress_msg_id=#{inspect(progress_msg_id)}"
    )

    directive_engine = meta0[:directive_engine]

    if is_binary(directive_engine) and directive_engine != "" and is_binary(session_key) do
      callbacks.update_chat_state_last_engine.(session_key, directive_engine)
    end

    {model_hint, model_scope} =
      callbacks.resolve_model_hint.(state, session_key, chat_id, thread_id)

    {thinking_hint, thinking_scope} = callbacks.resolve_thinking_hint.(state, chat_id, thread_id)

    meta =
      meta0
      |> Map.put(:session_key, session_key)
      |> Map.put(:forked_session, forked?)
      |> maybe_put(:model, model_hint)
      |> maybe_put(:model_scope, model_scope)
      |> maybe_put(:thinking_level, thinking_hint)
      |> maybe_put(:thinking_scope, thinking_scope)

    meta =
      if is_binary(model_hint) and model_hint != "" and not is_binary(meta[:engine_id]) do
        Map.put(meta, :engine_id, @model_default_engine)
      else
        meta
      end

    _ =
      callbacks.maybe_index_telegram_msg_session.(state, scope, session_key, [
        progress_msg_id,
        user_msg_id
      ])

    state =
      if is_integer(progress_msg_id) and is_binary(session_key) do
        callbacks.maybe_subscribe_to_session.(session_key)

        reaction_run = %{
          chat_id: chat_id,
          thread_id: thread_id,
          user_msg_id: user_msg_id,
          session_key: session_key
        }

        %{state | reaction_runs: Map.put(state.reaction_runs, session_key, reaction_run)}
      else
        state
      end

    prompt = inbound.message.text || ""
    {explicit_resume, stripped_prompt} = callbacks.extract_explicit_resume_and_strip.(prompt)

    meta =
      if is_nil(meta[:resume]) and is_nil(meta["resume"]) and
           match?(%ResumeToken{}, explicit_resume) do
        Map.put(meta, :resume, explicit_resume)
      else
        meta
      end

    inbound = %{
      inbound
      | meta: meta,
        message: Map.put(inbound.message || %{}, :text, stripped_prompt)
    }

    route_to_router(inbound)
    state
  end

  def execute_inbound_message(state, _inbound, _callbacks), do: state

  defp send_progress(state, chat_id, reply_to_message_id) do
    if is_integer(reply_to_message_id) do
      case state.api_mod.set_message_reaction(
             state.token,
             chat_id,
             reply_to_message_id,
             "👀",
             %{is_big: true}
           ) do
        {:ok, %{"ok" => true}} -> reply_to_message_id
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp route_to_router(inbound) do
    case LemonCore.RouterBridge.handle_inbound(inbound) do
      :ok ->
        :ok

      other ->
        meta = inbound.meta || %{}

        Logger.warning(
          "RouterBridge.handle_inbound failed for telegram inbound (chat_id=#{inspect(meta[:chat_id])} update_id=#{inspect(meta[:update_id])} msg_id=#{inspect(meta[:user_msg_id])}): " <>
            inspect(other)
        )

        LemonCore.Telemetry.channel_inbound("telegram", %{
          peer_id: inbound.peer.id,
          peer_kind: inbound.peer.kind
        })
    end
  rescue
    e ->
      Logger.warning("Failed to route inbound message: #{inspect(e)}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
