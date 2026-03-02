defmodule LemonCore.ChannelRoute do
  @moduledoc """
  Channel-neutral route descriptor identifying where output should be delivered.

  Lives in lemon_core so both lemon_router and lemon_channels can reference it
  without creating a circular dependency.
  """

  @enforce_keys [:channel_id, :account_id, :peer_kind, :peer_id]
  defstruct [:channel_id, :account_id, :peer_kind, :peer_id, :thread_id]

  @type t :: %__MODULE__{
          channel_id: String.t(),
          account_id: String.t(),
          peer_kind: atom(),
          peer_id: String.t(),
          thread_id: String.t() | nil
        }
end
