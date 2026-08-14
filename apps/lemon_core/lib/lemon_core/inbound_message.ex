defmodule LemonCore.InboundMessage do
  @moduledoc """
  Normalized inbound message type (shared).

  This struct represents an inbound message from any channel, normalized to a
  common format for processing by the router. It lives in `:lemon_core` so
  channel adapters do not need a compile-time dependency on `:lemon_router`.

  Every field is transport-independent; an adapter maps its own vocabulary onto
  them:

    * `channel_id` — the transport that delivered the message, e.g. `"email"`.
      Adapters use their own registered channel id.
    * `account_id` — which credential/bot/mailbox of that transport received
      it, for hosts running more than one.
    * `peer` — where the conversation lives: `:dm`, `:group` or `:channel`,
      the transport's own conversation id, and an optional `thread_id` for
      transports with threads (forum topics, mail threads, thread replies).
    * `sender` — who sent it, with the transport's user id plus whatever
      display information it exposes. `nil` when the transport is anonymous.
    * `message` — id, text, unix timestamp and the id this message replies to.
      Text is always a binary; a message with no text is `""`, not `nil`.
    * `raw` — the untouched payload the adapter received, for adapter-side
      features the normalized shape does not cover.
    * `meta` — adapter-owned extras. Nothing outside the owning adapter should
      depend on a particular key.

  Adapters build the struct directly (or through `new/1`); the library ships no
  per-transport constructor.
  """

  @enforce_keys [:channel_id, :account_id, :peer, :message]
  defstruct [:channel_id, :account_id, :peer, :sender, :message, :raw, :meta]

  @type peer :: %{
          kind: :dm | :group | :channel,
          id: binary(),
          thread_id: binary() | nil
        }

  @type sender :: %{
          optional(:bot) => boolean(),
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
end
