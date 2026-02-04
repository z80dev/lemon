defmodule LemonControlPlane.Methods.ExecApprovalsGet do
  @moduledoc """
  Handler for the exec.approvals.get method.

  Gets the current approval policy.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "exec.approvals.get"

  @impl true
  def scopes, do: [:approvals]

  @impl true
  def handle(_params, _ctx) do
    # Get the global policy map (tool -> disposition)
    policy = LemonCore.Store.get(:exec_approvals_policy_map, :global) || %{}

    # Get specific approvals (tool+action combinations)
    approvals =
      LemonCore.Store.list(:exec_approvals_policy)
      |> Enum.map(fn {{tool, action_hash}, approval} ->
        %{
          "tool" => tool,
          "actionHash" => if(action_hash == :any, do: "*", else: action_hash),
          "scope" => "global",
          "approved" => approval.approved,
          "approvedAtMs" => approval[:approved_at_ms]
        }
      end)

    # Get pending requests
    pending =
      LemonCore.Store.list(:exec_approvals_pending)
      |> Enum.map(fn {_id, p} ->
        %{
          "id" => p.id,
          "runId" => p.run_id,
          "sessionKey" => p.session_key,
          "agentId" => p[:agent_id],
          "tool" => p.tool,
          "rationale" => p.rationale,
          "requestedAtMs" => p.requested_at_ms,
          "expiresAtMs" => p.expires_at_ms
        }
      end)
      |> Enum.filter(fn p -> p["expiresAtMs"] > LemonCore.Clock.now_ms() end)

    {:ok, %{
      "policy" => policy,
      "approvals" => approvals,
      "pending" => pending
    }}
  end
end
