defmodule LemonControlPlane.Methods.ExecApprovalsGet do
  @moduledoc """
  Handler for the exec.approvals.get method.

  Gets the current approval policy.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.ExecApprovalStore

  @impl true
  def name, do: "exec.approvals.get"

  @impl true
  def scopes, do: [:approvals]

  @impl true
  def handle(_params, _ctx) do
    # Get the global policy map (tool -> disposition)
    policy = ExecApprovalStore.get_global_policy_map() || %{}

    # Get specific approvals (tool+action combinations)
    approvals =
      ExecApprovalStore.list_global_policies()
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
    now_ms = LemonCore.Clock.now_ms()

    pending =
      ExecApprovalStore.list_pending()
      |> Enum.map(fn {_id, p} -> p end)
      |> Enum.filter(&pending_active?(&1, now_ms))
      |> Enum.map(&format_pending/1)

    {:ok,
     %{
       "policy" => policy,
       "approvals" => approvals,
       "pending" => pending,
       "summary" => summary(policy, approvals, pending)
     }}
  end

  defp pending_active?(pending, now_ms) do
    case get_value(pending, :expires_at_ms) do
      nil -> true
      expires_at_ms when is_integer(expires_at_ms) -> expires_at_ms > now_ms
      _ -> false
    end
  end

  defp format_pending(pending) do
    %{
      "id" => get_value(pending, :id),
      "runId" => get_value(pending, :run_id),
      "sessionKey" => get_value(pending, :session_key),
      "agentId" => get_value(pending, :agent_id),
      "tool" => get_value(pending, :tool),
      "action" => redact_action(get_value(pending, :action) || %{}),
      "rationale" => get_value(pending, :rationale),
      "requestedAtMs" => get_value(pending, :requested_at_ms),
      "expiresAtMs" => get_value(pending, :expires_at_ms)
    }
  end

  defp get_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp summary(policy, approvals, pending) do
    %{
      "policyCount" => map_size(policy),
      "approvalCount" => length(approvals),
      "pendingCount" => length(pending),
      "pendingToolCounts" => count_by(pending, "tool"),
      "pendingAgentCounts" => count_by(pending, "agentId"),
      "expiredPendingOmitted" => true,
      "cleanup" => %{
        "includesPolicy" => true,
        "includesApprovalHashes" => true,
        "includesPendingActions" => true,
        "redactsPendingActionSecretKeys" => true,
        "includesRationales" => true,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp count_by(items, key) do
    items
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp redact_action(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      string_key = to_string(key)

      if sensitive_key?(string_key) do
        {string_key, %{"redacted" => true, "kind" => "secret"}}
      else
        {string_key, redact_action(value)}
      end
    end)
  end

  defp redact_action(list) when is_list(list), do: Enum.map(list, &redact_action/1)
  defp redact_action(value), do: value

  defp sensitive_key?(key) do
    normalized = String.downcase(key)

    Enum.any?(["token", "secret", "password", "api_key", "apikey", "credential", "cookie"], fn
      marker -> String.contains?(normalized, marker)
    end)
  end
end
