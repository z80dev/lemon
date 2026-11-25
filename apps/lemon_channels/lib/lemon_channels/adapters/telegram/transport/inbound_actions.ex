defmodule LemonChannels.Adapters.Telegram.Transport.InboundActions do
  @moduledoc """
  Telegram-local execution helpers for normal inbound message submission.

  This module owns the side effects that happen after command/session routing
  decides a message should be submitted onward. It stays local to the Telegram
  transport and avoids introducing a shared cross-channel action framework.
  """

  require Logger

  alias LemonChannels.Adapters.Telegram.Transport.MessageBuffer
  alias LemonChannels.SubmissionOutcome
  alias LemonChannels.Telegram.TransportShared
  alias LemonCore.ChatScope
  alias LemonCore.ResumeToken

  @type callbacks :: %{
          extract_explicit_resume_and_strip: (binary() ->
                                                {ResumeToken.t() | nil, binary()}
                                                | {:unsupported, binary()}),
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
          resolve_session_key: (map(), map(), ChatScope.t() | nil, map() ->
                                  {binary() | nil, boolean()}),
          send_submission_failure: (map(),
                                    integer(),
                                    integer()
                                    | nil,
                                    integer()
                                    | nil,
                                    binary() ->
                                      any()),
          send_system_message: (map(), integer(), integer() | nil, integer() | nil, binary() ->
                                  any())
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
    case callbacks.extract_explicit_resume_and_strip.(inbound.message.text || "") do
      {:unsupported, engine} ->
        reject_unsupported_resume(state, inbound, callbacks, engine)

      {explicit_resume, stripped_prompt} ->
        execute_native_inbound_message(
          state,
          inbound,
          callbacks,
          explicit_resume,
          stripped_prompt
        )
    end
  end

  def execute_inbound_message(state, _inbound, _callbacks), do: state

  @spec execute_native_inbound_message(
          map(),
          map(),
          callbacks(),
          ResumeToken.t() | nil,
          binary()
        ) :: map()
  defp execute_native_inbound_message(state, inbound, callbacks, explicit_resume, stripped_prompt)
       when is_map(inbound) and is_map(state) and is_map(callbacks) do
    {dedupe_refs, inbound} = pop_submission_dedupe_refs(inbound)
    {chat_id, thread_id, user_msg_id} = callbacks.extract_message_ids.(inbound)

    # The user message is the progress target in the run request. The visible
    # reaction is deferred until the router confirms acceptance.
    progress_msg_id =
      if is_integer(chat_id) and is_integer(user_msg_id), do: user_msg_id, else: nil

    scope =
      if is_integer(chat_id) do
        %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      end

    meta0 =
      inbound.meta
      |> drop_non_native_resume()
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

    # Model and thinking level come from the router (`PolicyStore` session and
    # chat rows), never from channel meta.
    meta =
      meta0
      |> Map.put(:session_key, session_key)
      |> Map.put(:forked_session, forked?)

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

    # An unreadable /resume selection rejects the submission (retry-safe:
    # nothing was sent) instead of running without the operator's selection.
    result =
      if meta[:selected_resume_unavailable],
        do: {:error, :resume_unavailable},
        else: route_to_router(state, inbound, chat_id, thread_id, session_key)

    case result do
      :ok ->
        track_accepted_submission(
          state,
          callbacks,
          scope,
          session_key,
          chat_id,
          thread_id,
          user_msg_id
        )

      {:error, _} = error ->
        if SubmissionOutcome.retry_safe?(error) do
          Enum.each(dedupe_refs, &TransportShared.forget_dedupe/1)
        end

        report_submission_failure(
          state,
          callbacks,
          error,
          chat_id,
          thread_id,
          user_msg_id
        )

        state
    end
  end

  defp track_accepted_submission(
         state,
         callbacks,
         scope,
         session_key,
         chat_id,
         thread_id,
         user_msg_id
       ) do
    progress_msg_id =
      if is_integer(chat_id) and is_integer(user_msg_id) do
        send_progress(state, chat_id, user_msg_id)
      end

    _ =
      callbacks.maybe_index_telegram_msg_session.(state, scope, session_key, [
        progress_msg_id,
        user_msg_id
      ])

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
  end

  defp report_submission_failure(
         state,
         callbacks,
         error,
         chat_id,
         thread_id,
         user_msg_id
       ) do
    if is_integer(chat_id) do
      text =
        if SubmissionOutcome.uncertain?(error) do
          "I couldn't confirm whether that request was accepted. Check the run status before retrying."
        else
          "I couldn't queue that request. Please try again."
        end

      _ = callbacks.send_submission_failure.(state, chat_id, thread_id, user_msg_id, text)
    end

    :ok
  end

  defp reject_unsupported_resume(state, inbound, callbacks, engine) do
    {chat_id, thread_id, user_msg_id} = callbacks.extract_message_ids.(inbound)

    if is_integer(chat_id) do
      _ =
        callbacks.send_system_message.(
          state,
          chat_id,
          thread_id,
          user_msg_id,
          "Top-level resume only supports Lemon sessions. Use `lemon resume <session-id>` or /resume to choose a native session; #{engine} resumes are unsupported here."
        )
    end

    state
  end

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

  defp route_to_router(state, inbound, chat_id, thread_id, session_key) do
    typing = [
      target: {:telegram, state.account_id, chat_id, thread_id},
      session_key: session_key,
      interval_ms: 4_500,
      send: fn -> state.api_mod.send_chat_action(state.token, chat_id, thread_id, "typing") end
    ]

    opts = [typing: typing] ++ update_run_identity(state, inbound, chat_id, thread_id)

    case LemonChannels.Runtime.submit_inbound(inbound, opts) do
      :ok ->
        :ok

      {:error, _} = error ->
        Logger.warning(
          "telegram inbound routing failed: reason=#{SubmissionOutcome.log_label(error)}"
        )

        error
    end
  end

  # A Telegram update id is stable across re-polls, so a replayed update maps
  # to the same run and the router admits it at most once.
  defp update_run_identity(state, inbound, chat_id, thread_id) do
    case (inbound.meta || %{})[:update_id] do
      update_id when is_integer(update_id) ->
        digest =
          {:telegram, state.account_id, chat_id, thread_id, update_id}
          |> :erlang.term_to_binary()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)
          |> binary_part(0, 32)

        [run_id: "run_telegram_" <> digest, replay_identity: "telegram:" <> digest]

      _ ->
        []
    end
  end

  defp pop_submission_dedupe_refs(inbound) do
    meta = inbound.meta || %{}

    {List.wrap(meta[:transport_dedupe_refs]),
     %{inbound | meta: Map.delete(meta, :transport_dedupe_refs)}}
  end

  defp drop_non_native_resume(meta) do
    Enum.reduce([:resume, "resume"], meta, fn key, acc ->
      case Map.get(acc, key) do
        %ResumeToken{engine: "lemon"} -> acc
        nil -> acc
        _ -> Map.delete(acc, key)
      end
    end)
  end
end
