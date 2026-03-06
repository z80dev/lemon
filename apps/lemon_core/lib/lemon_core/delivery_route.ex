defmodule LemonCore.DeliveryRoute do
  @moduledoc """
  Semantic delivery route from router to channels.
  """

  @enforce_keys [:channel_id, :account_id, :peer_kind, :peer_id]
  defstruct [:channel_id, :account_id, :peer_kind, :peer_id, :thread_id]

  @type t :: %__MODULE__{
          channel_id: String.t(),
          account_id: String.t(),
          peer_kind: atom() | String.t(),
          peer_id: String.t(),
          thread_id: String.t() | nil
        }
end
