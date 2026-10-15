defmodule LemonChannels.Adapters.Telegram.UserPrompt do
  @moduledoc false
  alias LemonChannels.Adapters.Telegram.Transport.UpdateProcessor
  alias LemonChannels.UserPromptSurface

  def handle(state, cb) do
    message = cb["message"] || %{}
    chat = message["chat"] || %{}

    kind =
      case chat["type"] do
        "private" -> :dm
        type when type in ["group", "supergroup"] -> :group
        "channel" -> :channel
        _ -> :unknown
      end

    peer = %{kind: kind, id: string(chat["id"]), thread_id: string(message["message_thread_id"])}

    result =
      if UpdateProcessor.authorized_callback_query?(state, cb) and
           is_integer(message["message_id"]) do
        UserPromptSurface.answer(
          cb["data"],
          "telegram",
          state.account_id,
          peer,
          string(get_in(cb, ["from", "id"]))
        )
      else
        {:error, :wrong_user}
      end

    notice =
      case result do
        :ok -> "Recorded"
        {:error, :wrong_user} -> "Only the user who started this run may answer here."
        {:error, :empty} -> "Choose at least one option first."
        _ -> "expired"
      end

    state.api_mod.answer_callback_query(state.token, cb["id"], %{"text" => notice})
  end

  defp string(nil), do: nil
  defp string(id), do: to_string(id)
end
