defmodule LemonCore.ChatScope do
  @moduledoc """
  Transport-specific chat identification.

  Identifies a unique chat context within a transport (e.g. Telegram, Discord, XMTP).
  The `topic_id` field is optional and used by transports that support threaded conversations.
  """

  @enforce_keys [:transport, :chat_id]
  defstruct [:transport, :chat_id, :topic_id]

  @type t :: %__MODULE__{
          transport: atom(),
          chat_id: integer(),
          topic_id: integer() | nil
        }
end
