defmodule LemonChannels.OutboundPayload do
  @moduledoc """
  Outbound payload for channel delivery.

  Represents a message to be delivered to a channel.
  """

  @enforce_keys [:channel_id, :account_id, :peer, :kind, :content]
  defstruct [
    :channel_id,
    :account_id,
    :peer,
    :kind,
    :content,
    :idempotency_key,
    :reply_to,
    :meta,
    # Optional outbox delivery acknowledgment.
    # When set, LemonChannels.Outbox will send `{tag, notify_ref, result}` to notify_pid.
    :notify_pid,
    :notify_ref
  ]

  @type peer :: %{
          kind: :dm | :group | :channel,
          id: binary(),
          thread_id: binary() | nil
        }

  @type kind :: :text | :edit | :delete | :reaction | :file | :voice

  @type content :: binary() | map()

  @type t :: %__MODULE__{
          channel_id: binary(),
          account_id: binary(),
          peer: peer(),
          kind: kind(),
          content: content(),
          idempotency_key: binary() | nil,
          reply_to: binary() | nil,
          meta: map() | nil,
          notify_pid: pid() | nil,
          notify_ref: reference() | nil
        }

  @doc """
  Create a new outbound payload.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc """
  Create a text message payload.
  """
  @spec text(channel_id :: binary(), account_id :: binary(), peer :: peer(), text :: binary(), opts :: keyword()) :: t()
  def text(channel_id, account_id, peer, text, opts \\ []) do
    new([
      channel_id: channel_id,
      account_id: account_id,
      peer: peer,
      kind: :text,
      content: text,
      idempotency_key: opts[:idempotency_key],
      reply_to: opts[:reply_to],
      meta: opts[:meta],
      notify_pid: opts[:notify_pid],
      notify_ref: opts[:notify_ref]
    ])
  end

  @doc """
  Create an edit message payload.
  """
  @spec edit(channel_id :: binary(), account_id :: binary(), peer :: peer(), message_id :: binary(), text :: binary(), opts :: keyword()) :: t()
  def edit(channel_id, account_id, peer, message_id, text, opts \\ []) do
    new([
      channel_id: channel_id,
      account_id: account_id,
      peer: peer,
      kind: :edit,
      content: %{message_id: message_id, text: text},
      idempotency_key: opts[:idempotency_key],
      meta: opts[:meta],
      notify_pid: opts[:notify_pid],
      notify_ref: opts[:notify_ref]
    ])
  end
end
