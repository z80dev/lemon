defmodule LemonCore.Events.ApprovalPending do
  @moduledoc """
  A tool execution awaiting a human decision. Carried inside the approval events and
  stored verbatim in `LemonCore.ExecApprovalStore`. The invocation context key is
  private owner state: it is retained in storage, never direct JSON or RPC receipts.
  """

  use LemonCore.Events.Payload,
    type: :approval_pending,
    enforce: [:id, :tool],
    private_fields: [:invocation_context_key],
    fields: [
      id: nil,
      run_id: nil,
      session_id: nil,
      session_key: nil,
      agent_id: nil,
      invocation_context_key: nil,
      tool: nil,
      tool_call_id: nil,
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
          invocation_context_key: String.t() | nil,
          tool: String.t(),
          tool_call_id: String.t() | nil,
          action: map() | nil,
          rationale: String.t() | nil,
          requested_at_ms: non_neg_integer() | nil,
          expires_at_ms: non_neg_integer() | nil
        }
end
