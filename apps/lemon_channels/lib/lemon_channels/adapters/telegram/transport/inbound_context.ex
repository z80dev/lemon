defmodule LemonChannels.Adapters.Telegram.Transport.InboundContext do
  @moduledoc """
  Telegram-local normalized inbound context for transport ingress handling.

  This is intentionally scoped to the Telegram transport tree. It provides a
  small normalization boundary for Telegram updates and transport timer events
  without introducing a premature cross-channel abstraction.
  """

  @enforce_keys [:kind]
  defstruct [
    :kind,
    :account_id,
    :chat_id,
    :thread_id,
    :sender_id,
    :message_id,
    :user_msg_id,
    :text,
    :reply_to_text,
    :reply_to_id,
    :media_group_id,
    :callback_id,
    :callback_data,
    :scope_key,
    :debounce_ref,
    :raw_update,
    :inbound,
    meta: %{}
  ]

  @type kind ::
          :message | :callback_query | :buffer_flush | :media_group_flush | :approval_requested

  @type t :: %__MODULE__{
          kind: kind(),
          account_id: binary() | nil,
          chat_id: integer() | nil,
          thread_id: integer() | nil,
          sender_id: integer() | binary() | nil,
          message_id: integer() | nil,
          user_msg_id: integer() | nil,
          text: binary() | nil,
          reply_to_text: binary() | nil,
          reply_to_id: integer() | nil,
          media_group_id: binary() | nil,
          callback_id: binary() | nil,
          callback_data: binary() | nil,
          scope_key: term(),
          debounce_ref: reference() | nil,
          raw_update: term(),
          inbound: map() | nil,
          meta: map()
        }
end
