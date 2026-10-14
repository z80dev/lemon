defmodule LemonControlPlane.Methods.ExecApprovalsGet do
  @moduledoc """
  Handler for the exec.approvals.get method.

  Gets the current approval policy and active pending requests. Pending actions
  redact credential fields and text. The action's exact `authorization_url` field
  may retain a credential-free HTTP(S) URL so operators can complete OAuth;
  URLs containing userinfo or recognizable credentials remain redacted.
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

  @doc false
  def format_pending(pending) do
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

      cond do
        string_key == "authorization_url" and safe_authorization_url?(value) ->
          {string_key, value}

        LemonCore.Redact.sensitive_key?(string_key) ->
          {string_key, %{"redacted" => true, "kind" => "secret"}}

        true ->
          {string_key, redact_action(value)}
      end
    end)
  end

  defp redact_action(list) when is_list(list), do: Enum.map(list, &redact_action/1)
  defp redact_action(value), do: LemonCore.Redact.text(value)

  defp safe_authorization_url?(value) when is_binary(value) do
    with {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} <- URI.new(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      decoded = URI.decode(value)
      LemonCore.Redact.text(decoded) == decoded
    else
      _ -> false
    end
  end

  defp safe_authorization_url?(_), do: false
end
