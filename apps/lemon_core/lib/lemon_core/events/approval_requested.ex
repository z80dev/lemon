defmodule LemonCore.Events.ApprovalRequested do
  @moduledoc """
  A tool call is blocked awaiting approval. Published on `exec_approvals`, where two chat
  plugins, the ACP server and the requesting process itself are listening.
  """

  use LemonCore.Events.Payload,
    type: :approval_requested,
    enforce: [:approval_id, :pending],
    fields: [approval_id: nil, pending: nil]

  alias LemonCore.Events.ApprovalPending

  @type t :: %__MODULE__{
          approval_id: String.t(),
          pending: ApprovalPending.t()
        }

  @doc "Build from a legacy map, coercing the nested pending record."
  @spec from_map(map() | struct() | keyword()) :: t()
  def from_map(%__MODULE__{} = payload), do: payload

  def from_map(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    pending = Map.get(attrs, :pending) || Map.get(attrs, "pending") || %{}

    %__MODULE__{
      approval_id: Map.get(attrs, :approval_id) || Map.get(attrs, "approval_id"),
      pending: ApprovalPending.from_map(pending)
    }
  end
end
