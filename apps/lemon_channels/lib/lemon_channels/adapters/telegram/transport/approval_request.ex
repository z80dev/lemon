defmodule LemonChannels.Adapters.Telegram.Transport.ApprovalRequest do
  @moduledoc "Telegram approval requests and callbacks use the shared exact-snapshot boundary."

  alias LemonChannels.Adapters.Telegram.Transport.UpdateProcessor
  alias LemonChannels.RemoteApproval

  def send(state, payload, opts \\ []) do
    with {:ok, pending, target} <-
           RemoteApproval.request(
             payload,
             "telegram",
             state.account_id,
             &authorized?(state, &1),
             opts
           ) do
      markup = %{
        "inline_keyboard" => [
          [
            %{
              "text" => "Approve once",
              "callback_data" => RemoteApproval.callback(pending, :approve_once)
            },
            %{"text" => "Deny", "callback_data" => RemoteApproval.callback(pending, :deny)}
          ]
        ]
      }

      RemoteApproval.enqueue(
        target,
        "Approval requested: #{pending.tool}\n\nAction: #{RemoteApproval.action_text(pending.action)}\n\nChoose:",
        %{reply_markup: markup},
        Keyword.put(
          opts,
          :idempotency_key,
          "approval:telegram:#{RemoteApproval.callback(pending, :approve_once)}"
        )
      )
    end
  end

  def handle_callback(state, cb, opts \\ []) do
    result =
      RemoteApproval.resolve(
        cb["data"],
        "telegram",
        state.account_id,
        fn target ->
          authorized?(state, target) and callback_matches?(cb, target)
        end,
        opts
      )

    case result do
      {:ok, target, decision} ->
        _ =
          RemoteApproval.edit(
            target,
            cb["message"]["message_id"],
            decision,
            %{reply_markup: %{"inline_keyboard" => []}},
            opts
          )

        state.api_mod.answer_callback_query(state.token, cb["id"], %{"text" => "Recorded"})

      _ ->
        state.api_mod.answer_callback_query(state.token, cb["id"], %{
          "text" => "Approval rejected or unavailable; request unchanged"
        })
    end
  end

  def text_authorizer(state, message) do
    fn target ->
      authorized?(state, target) and
        callback_matches?(%{"message" => message}, target)
    end
  end

  defp authorized?(state, target) do
    UpdateProcessor.authorized_callback_query?(state, %{
      "message" => %{
        "chat" => %{"id" => RemoteApproval.integer(target.peer.id)},
        "message_thread_id" => RemoteApproval.integer(target.peer.thread_id)
      }
    })
  end

  defp callback_matches?(cb, target) do
    msg = cb["message"] || %{}
    chat = msg["chat"] || %{}

    kind =
      case chat["type"] do
        "private" -> :dm
        "group" -> :group
        "supergroup" -> :group
        "channel" -> :channel
        _ -> :unknown
      end

    is_integer(msg["message_id"]) and msg["message_id"] > 0 and
      is_integer(chat["id"]) and chat["id"] == RemoteApproval.integer(target.peer.id) and
      kind == target.peer.kind and
      msg["message_thread_id"] == RemoteApproval.integer(target.peer.thread_id)
  end
end
