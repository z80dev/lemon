defmodule LemonRouter.ApprovalsBridge do
  @moduledoc """
  Bridge to the approvals system for tool execution gating.

  This module provides the interface for tools to request approval
  and for the control plane to resolve approval requests.

  ## Approval Scopes

  Approvals can be granted at different scopes (per parity contract):

  - `:approve_once` - Single request only (not persisted)
  - `:approve_session` - For the session (persisted per session_key)
  - `:approve_agent` - For the agent (persisted per agent_id)
  - `:approve_global` - Globally for all (persisted globally)

  ## Storage Keys

  - Global: `{tool, action_hash}`
  - Agent: `{agent_id, tool, action_hash}`
  - Session: `{session_key, tool, action_hash}`
  """

  @type approval_id :: binary()

  @deprecated "Use LemonCore.ExecApprovals.request/1"
  @spec request(map()) ::
          {:ok, :approved, scope :: atom()}
          | {:ok, :denied}
          | {:error, :timeout}
  defdelegate request(params), to: LemonCore.ExecApprovals

  @doc """
  Resolve a pending approval request.

  ## Parameters

  - `approval_id` - The approval request ID
  - `decision` - One of:
    - `:approve_once` - Approve this specific request
    - `:approve_session` - Approve for the session
    - `:approve_agent` - Approve for the agent
    - `:approve_global` - Approve globally
    - `:deny` - Deny the request
  """
  @deprecated "Use LemonCore.ExecApprovals.resolve/2"
  @spec resolve(approval_id(), decision :: atom()) :: :ok
  defdelegate resolve(approval_id, decision), to: LemonCore.ExecApprovals
end
