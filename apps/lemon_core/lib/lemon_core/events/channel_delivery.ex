defmodule LemonCore.Events.ChannelDelivery do
  @moduledoc """
  An outbound delivery intent was dispatched to a channel renderer. Published on `channels`.

  Emitted by `LemonChannels.Dispatcher` after the dispatch result is known, for both
  successful and failed dispatches — check `ok`. This is the first (and so far only)
  publisher on the `channels` topic, which `LemonControlPlane.EventBridge` forwards to WS
  clients as `channel.delivery`.

  `text_preview` is a bounded excerpt of the outbound text (never the full body), and
  `error` is a bounded `inspect/2` rendering of the failure reason, so the payload stays
  small and JSON-encodable regardless of what was sent.
  """

  use LemonCore.Events.Payload,
    type: :channel_delivery,
    enforce: [:intent_id, :channel_id, :kind, :ok],
    fields: [
      intent_id: nil,
      run_id: nil,
      session_key: nil,
      channel_id: nil,
      account_id: nil,
      peer_kind: nil,
      peer_id: nil,
      thread_id: nil,
      kind: nil,
      text_preview: nil,
      ok: nil,
      error: nil,
      duration_ms: nil,
      ts_ms: nil
    ]

  @type t :: %__MODULE__{
          intent_id: String.t(),
          run_id: String.t() | nil,
          session_key: String.t() | nil,
          channel_id: String.t(),
          account_id: String.t() | nil,
          peer_kind: atom() | String.t() | nil,
          peer_id: String.t() | nil,
          thread_id: String.t() | nil,
          kind: atom() | String.t(),
          text_preview: String.t() | nil,
          ok: boolean(),
          error: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          ts_ms: non_neg_integer() | nil
        }
end
