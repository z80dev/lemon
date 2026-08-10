defmodule LemonCore.Events.ApprovalResolved do
  @moduledoc """
  A pending approval was decided, denied or timed out. Published on `exec_approvals`.
  """

  use LemonCore.Events.Payload,
    type: :approval_resolved,
    enforce: [:approval_id, :decision],
    fields: [approval_id: nil, decision: nil, pending: nil]

  alias LemonCore.Events.ApprovalPending

  @decisions [
    :approve_once,
    :approve_session,
    :approve_agent,
    :approve_global,
    :deny,
    :timeout
  ]

  @type decision ::
          :approve_once | :approve_session | :approve_agent | :approve_global | :deny | :timeout
  @type t :: %__MODULE__{
          approval_id: String.t(),
          decision: decision(),
          pending: ApprovalPending.t() | nil
        }

  @doc "The accepted decisions."
  @spec decisions() :: [decision()]
  def decisions, do: @decisions

  @doc "Build from a legacy map, coercing the nested pending record when present."
  @spec from_map(map() | struct() | keyword()) :: t()
  def from_map(%__MODULE__{} = payload), do: payload

  def from_map(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    pending =
      case Map.get(attrs, :pending) || Map.get(attrs, "pending") do
        nil -> nil
        pending -> ApprovalPending.from_map(pending)
      end

    %__MODULE__{
      approval_id: Map.get(attrs, :approval_id) || Map.get(attrs, "approval_id"),
      decision: Map.get(attrs, :decision) || Map.get(attrs, "decision"),
      pending: pending
    }
  end
end
