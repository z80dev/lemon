defmodule LemonCore.Events.ApprovalPending do
  @moduledoc """
  A tool execution awaiting a human decision. Carried inside the approval events and
  stored verbatim in `LemonCore.ExecApprovalStore`.
  """

  use LemonCore.Events.Payload,
    type: :approval_pending,
    enforce: [:id, :tool],
    fields: [
      id: nil,
      run_id: nil,
      session_id: nil,
      session_key: nil,
      agent_id: nil,
      tool: nil,
      action: nil,
      rationale: nil,
      requested_at_ms: nil,
      expires_at_ms: nil
    ]

  @type t :: %__MODULE__{
          id: String.t(),
          run_id: String.t() | nil,
          session_id: String.t() | nil,
          session_key: String.t() | nil,
          agent_id: String.t() | nil,
          tool: String.t(),
          action: map() | nil,
          rationale: String.t() | nil,
          requested_at_ms: non_neg_integer() | nil,
          expires_at_ms: non_neg_integer() | nil
        }
end
