defmodule LemonControlPlane.Methods.ExecApprovalsNodeGet do
  @moduledoc """
  Handler for the exec.approvals.node.get method.

  Gets tool approval policy for a specific node.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "exec.approvals.node.get"

  @impl true
  def scopes, do: [:read, :approvals]

  @impl true
  def handle(params, _ctx) do
    node_id = params["nodeId"]

    if is_nil(node_id) do
      {:error, {:invalid_request, "nodeId is required", nil}}
    else
      policy = get_node_policy(node_id)
      approvals = get_node_approvals(node_id)
      {:ok, %{"nodeId" => node_id, "policy" => policy, "approvals" => approvals}}
    end
  end

  defp get_node_policy(node_id) do
    case LemonCore.Store.get(:exec_approvals_policy_node_map, node_id) do
      nil -> %{}
      policy -> policy
    end
  rescue
    _ -> %{}
  end

  defp get_node_approvals(node_id) do
    LemonCore.Store.list(:exec_approvals_policy_node)
    |> Enum.filter(fn
      {{^node_id, _tool, _hash}, _approval} -> true
      _ -> false
    end)
    |> Enum.map(fn {{_node_id, tool, action_hash}, approval} ->
      %{
        "tool" => tool,
        "actionHash" => if(action_hash == :any, do: "*", else: action_hash),
        "approved" => approval.approved,
        "approvedAtMs" => approval[:approved_at_ms]
      }
    end)
  rescue
    _ -> []
  end
end
