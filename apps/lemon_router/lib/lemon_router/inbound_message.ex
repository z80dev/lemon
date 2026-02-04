defmodule LemonRouter.InboundMessage do
  @moduledoc """
  Normalized inbound message type.

  This struct represents an inbound message from any channel,
  normalized to a common format for processing by the router.
  """

  @enforce_keys [:channel_id, :account_id, :peer, :message]
  defstruct [:channel_id, :account_id, :peer, :sender, :message, :raw, :meta]

  @type peer :: %{
          kind: :dm | :group | :channel,
          id: binary(),
          thread_id: binary() | nil
        }

  @type sender :: %{
          id: binary(),
          username: binary() | nil,
          display_name: binary() | nil
        }

  @type message :: %{
          id: binary() | nil,
          text: binary(),
          timestamp: non_neg_integer() | nil,
          reply_to_id: binary() | nil
        }

  @type t :: %__MODULE__{
          channel_id: binary(),
          account_id: binary(),
          peer: peer(),
          sender: sender() | nil,
          message: message(),
          raw: term(),
          meta: map() | nil
        }

  @doc """
  Create a new InboundMessage.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Create an InboundMessage from Telegram update data.
  """
  @spec from_telegram(transport :: atom(), chat_id :: integer(), message :: map()) :: t()
  def from_telegram(transport, chat_id, message) do
    peer_kind =
      cond do
        message["chat"]["type"] == "private" -> :dm
        message["chat"]["type"] in ["group", "supergroup"] -> :group
        message["chat"]["type"] == "channel" -> :channel
        true -> :dm
      end

    sender =
      case message["from"] do
        nil ->
          nil

        from ->
          %{
            id: to_string(from["id"]),
            username: from["username"],
            display_name: from["first_name"]
          }
      end

    %__MODULE__{
      channel_id: "telegram",
      account_id: to_string(transport),
      peer: %{
        kind: peer_kind,
        id: to_string(chat_id),
        thread_id: message["message_thread_id"] && to_string(message["message_thread_id"])
      },
      sender: sender,
      message: %{
        id: message["message_id"] && to_string(message["message_id"]),
        text: message["text"] || "",
        timestamp: message["date"],
        reply_to_id:
          message["reply_to_message"] && to_string(message["reply_to_message"]["message_id"])
      },
      raw: message,
      meta: %{
        chat_id: chat_id,
        user_msg_id: message["message_id"]
      }
    }
  end
end
