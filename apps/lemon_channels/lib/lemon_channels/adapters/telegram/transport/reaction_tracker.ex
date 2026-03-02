defmodule LemonChannels.Adapters.Telegram.Transport.ReactionTracker do
  @moduledoc """
  Tracks in-flight runs and sets Telegram message reactions to indicate progress
  and completion status.

  When a user message is submitted, a "👀" reaction is placed to show the bot
  is processing. On run completion the reaction is updated to "✅" (success) or
  "❌" (failure). The tracker also manages Bus subscriptions for session and run
  topics.
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Set a progress reaction (👀) on the user's message.

  Returns the message_id that received the reaction, or nil on failure.
  """
  def send_progress(state, chat_id, _thread_id, reply_to_message_id) do
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
    else
      nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Register a run for reaction tracking.

  Subscribes to the session topic and stores the run metadata so that
  `handle_run_completed/2` can update the reaction when the run finishes.

  Returns the updated state.
  """
  def track_run(state, progress_msg_id, session_key, chat_id, thread_id, user_msg_id) do
    if is_integer(progress_msg_id) and is_binary(session_key) do
      maybe_subscribe_to_session(session_key)

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

  @doc """
  Handle a run_completed event by updating the reaction on the original
  user message.

  Returns the updated state.
  """
  def handle_run_completed(state, event, async_task_fn) do
    meta = (event.meta || %{})
    session_key = meta[:session_key] || meta["session_key"]

    case session_key && Map.get(state.reaction_runs, session_key) do
      %{
        chat_id: chat_id,
        thread_id: _thread_id,
        user_msg_id: user_msg_id
      } = _reaction_run ->
        ok? =
          case event.payload do
            %{completed: %{ok: ok}} when is_boolean(ok) -> ok
            %{ok: ok} when is_boolean(ok) -> ok
            _ -> true
          end

        # Update reaction: ✅ for success, ❌ for failure
        reaction_emoji = if ok?, do: "✅", else: "❌"

        _ =
          async_task_fn.(fn ->
            state.api_mod.set_message_reaction(
              state.token,
              chat_id,
              user_msg_id,
              reaction_emoji,
              %{is_big: true}
            )
          end)

        # Unsubscribe from session topic and remove from tracking
        if Code.ensure_loaded?(LemonCore.Bus) and
             function_exported?(LemonCore.Bus, :unsubscribe, 1) do
          topic = LemonCore.Bus.session_topic(session_key)
          _ = LemonCore.Bus.unsubscribe(topic)
        end

        %{state | reaction_runs: Map.delete(state.reaction_runs, session_key)}

      _ ->
        state
    end
  rescue
    _ -> state
  end

  @doc """
  Subscribe to a session's Bus topic for run completion events.
  """
  def maybe_subscribe_to_session(session_key) when is_binary(session_key) do
    if Code.ensure_loaded?(LemonCore.Bus) and
         function_exported?(LemonCore.Bus, :subscribe, 1) do
      topic = LemonCore.Bus.session_topic(session_key)
      _ = LemonCore.Bus.subscribe(topic)
    end
  end

  @doc """
  Subscribe to a specific run's Bus topic.
  """
  def maybe_subscribe_to_run(run_id) do
    if Code.ensure_loaded?(LemonCore.Bus) and
         function_exported?(LemonCore.Bus, :subscribe, 1) do
      topic = LemonCore.Bus.run_topic(run_id)
      _ = LemonCore.Bus.subscribe(topic)
    end
  end
end
