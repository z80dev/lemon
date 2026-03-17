defmodule LemonChannels.Adapters.WhatsApp.Transport.CommandRouter do
  @moduledoc """
  Command and message-routing decision tree for the WhatsApp transport shell.

  Simpler than Telegram's router: no media groups, no file commands, no
  trigger mode, no bot username handling.
  """

  require Logger

  alias LemonChannels.Adapters.WhatsApp.Transport.Commands
  alias LemonChannels.Adapters.WhatsApp.Transport.MessageBuffer

  @type callbacks :: %{
          handle_model_command: (map(), map() -> map()),
          handle_new_session: (map(), map(), binary() | nil -> map()),
          handle_thinking_command: (map(), map() -> map()),
          maybe_cancel_by_reply: (map(), map() -> any()),
          maybe_mark_fork_when_busy: (map(), map() -> map()),
          maybe_mark_new_session_pending: (map(), map() -> map()),
          maybe_transcribe_voice: (map(), map() -> map()),
          should_ignore_for_mention_gate?: (map(), map(), binary() -> boolean()),
          submit_inbound_now: (map(), map() -> map())
        }

  @spec handle_inbound_message(map(), map(), callbacks()) :: map()
  def handle_inbound_message(state, inbound, callbacks) do
    text = inbound.message.text || ""

    cond do
      # Voice note → transcribe
      has_voice_note?(inbound) ->
        callbacks.maybe_transcribe_voice.(state, inbound)

      # /new command
      Commands.new_command?(text) ->
        args = Commands.command_args(text, "new")
        callbacks.handle_new_session.(state, inbound, args)

      # /model command
      Commands.model_command?(text) ->
        callbacks.handle_model_command.(state, inbound)

      # /thinking command
      Commands.thinking_command?(text) ->
        callbacks.handle_thinking_command.(state, inbound)

      # /cancel command
      Commands.cancel_command?(text) ->
        callbacks.maybe_cancel_by_reply.(state, inbound)
        state

      # Group mention gating
      callbacks.should_ignore_for_mention_gate?.(state, inbound, text) ->
        state

      # Regular message → buffer
      true ->
        inbound = callbacks.maybe_mark_new_session_pending.(state, inbound)
        inbound = callbacks.maybe_mark_fork_when_busy.(state, inbound)

        if Commands.command?(text) do
          callbacks.submit_inbound_now.(state, inbound)
        else
          MessageBuffer.enqueue_buffer(state, inbound)
        end
    end
  rescue
    e ->
      Logger.warning(
        "WhatsApp inbound handler crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      state
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp has_voice_note?(inbound) do
    meta = inbound.meta || %{}
    meta[:media_type] == "audio" and not is_nil(meta[:media_path])
  end
end
