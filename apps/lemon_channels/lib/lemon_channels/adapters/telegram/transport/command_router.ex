defmodule LemonChannels.Adapters.Telegram.Transport.CommandRouter do
  @moduledoc """
  Command and message-routing decision tree for the Telegram transport shell.
  """

  require Logger

  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.Adapters.Telegram.Transport.FileOperations
  alias LemonChannels.Adapters.Telegram.Transport.MediaGroups
  alias LemonChannels.Adapters.Telegram.Transport.MessageBuffer

  @type callbacks :: %{
          bot_username: binary() | nil,
          handle_cwd_command: (map(), map() -> map()),
          handle_media_auto_put: (map(), map() -> map()),
          handle_model_command: (map(), map() -> map()),
          handle_new_session: (map(), map(), binary() | nil -> map()),
          handle_reload_command: (map(), map() -> map()),
          handle_resume_command: (map(), map() -> map()),
          handle_thinking_command: (map(), map() -> map()),
          handle_topic_command: (map(), map() -> map()),
          handle_trigger_command: (map(), map() -> map()),
          maybe_apply_selected_resume: (map(), map(), binary() -> map()),
          maybe_cancel_by_reply: (map(), map() -> any()),
          maybe_handle_model_picker_input: (map(), map(), binary() -> {map(), boolean()}),
          maybe_log_drop: (map(), map(), atom() -> any()),
          maybe_mark_fork_when_busy: (map(), map() -> map()),
          maybe_mark_new_session_pending: (map(), map() -> map()),
          maybe_switch_session_from_reply: (map(), map() -> {map(), map()}),
          should_ignore_for_trigger?: (map(), map(), binary() -> boolean()),
          submit_inbound_now: (map(), map() -> map())
        }

  @spec handle_inbound_message(map(), map(), callbacks()) :: map()
  def handle_inbound_message(state, inbound, callbacks) do
    text = inbound.message.text || ""
    original_text = text
    bot_username = callbacks.bot_username

    {state, handled_model_picker?} =
      callbacks.maybe_handle_model_picker_input.(state, inbound, original_text)

    if handled_model_picker? do
      state
    else
      cond do
        MediaGroups.media_group_member?(inbound) and
            MediaGroups.media_group_exists?(state, inbound) ->
          MediaGroups.enqueue_media_group(state, inbound)

        Commands.file_command?(original_text, bot_username) and
            MediaGroups.media_group_member?(inbound) ->
          MediaGroups.enqueue_media_group(state, inbound)

        Commands.file_command?(original_text, bot_username) ->
          FileOperations.handle_file_command(state, inbound)

        FileOperations.should_auto_put_media?(state, inbound) ->
          if MediaGroups.media_group_member?(inbound) do
            MediaGroups.enqueue_media_group(state, inbound)
          else
            callbacks.handle_media_auto_put.(state, inbound)
          end

        Commands.trigger_command?(original_text, bot_username) ->
          callbacks.handle_trigger_command.(state, inbound)

        Commands.cwd_command?(original_text, bot_username) ->
          callbacks.handle_cwd_command.(state, inbound)

        Commands.topic_command?(original_text, bot_username) ->
          callbacks.handle_topic_command.(state, inbound)

        Commands.resume_command?(original_text, bot_username) ->
          callbacks.handle_resume_command.(state, inbound)

        Commands.model_command?(original_text, bot_username) ->
          callbacks.handle_model_command.(state, inbound)

        Commands.thinking_command?(original_text, bot_username) ->
          callbacks.handle_thinking_command.(state, inbound)

        Commands.reload_command?(original_text, bot_username) ->
          callbacks.handle_reload_command.(state, inbound)

        Commands.new_command?(original_text, bot_username) ->
          args = Commands.telegram_command_args(original_text, "new")
          callbacks.handle_new_session.(state, inbound, args)

        Commands.cancel_command?(original_text, bot_username) ->
          callbacks.maybe_cancel_by_reply.(state, inbound)
          state

        true ->
          cond do
            callbacks.should_ignore_for_trigger?.(state, inbound, original_text) ->
              callbacks.maybe_log_drop.(state, inbound, :trigger_mentions)
              state

            true ->
              inbound = callbacks.maybe_mark_new_session_pending.(state, inbound)
              inbound = callbacks.maybe_mark_fork_when_busy.(state, inbound)
              {state, inbound} = callbacks.maybe_switch_session_from_reply.(state, inbound)
              inbound = callbacks.maybe_apply_selected_resume.(state, inbound, original_text)

              if Commands.command_message_for_bot?(original_text, bot_username) do
                callbacks.submit_inbound_now.(state, inbound)
              else
                MessageBuffer.enqueue_buffer(state, inbound)
              end
          end
      end
    end
  rescue
    e ->
      meta = inbound.meta || %{}

      Logger.warning(
        "Telegram inbound handler crashed (chat_id=#{inspect(meta[:chat_id])} update_id=#{inspect(meta[:update_id])} msg_id=#{inspect(meta[:user_msg_id])}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      state
  end
end
