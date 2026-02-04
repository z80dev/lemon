defmodule LemonControlPlane.Methods.ExecApprovalsNodeSet do
  @moduledoc """
  Handler for the exec.approvals.node.set method.

  Sets tool approval policy for a specific node. Supports two modes:

  ## Policy Mode
  Sets which tools require approval for the node:
  ```json
  {"nodeId": "node-1", "policy": {"bash": "require", "write": "allow"}}
  ```

  ## Pre-approval Mode
  Pre-approves specific tool+action combinations for the node:
  ```json
  {"nodeId": "node-1", "approvals": [{"tool": "bash", "action": {"command": "npm test"}}]}
  ```
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "exec.approvals.node.set"

  @impl true
  def scopes, do: [:admin, :approvals]

  @impl true
  def handle(params, _ctx) do
    node_id = params["nodeId"]
    policy = params["policy"]
    approvals = params["approvals"]

    cond do
      is_nil(node_id) ->
        {:error, {:invalid_request, "nodeId is required", nil}}

      not is_nil(approvals) ->
        # Pre-approval mode: store specific tool+action approvals for node
        case set_node_approvals(node_id, approvals) do
          {:ok, count} ->
            {:ok, %{"success" => true, "nodeId" => node_id, "approvals_set" => count}}

          {:error, reason} ->
            {:error, {:internal_error, "Failed to set node approvals", reason}}
        end

      not is_nil(policy) ->
        # Policy mode: store tool-level policy for node
        case set_node_policy(node_id, policy) do
          :ok ->
            {:ok, %{"success" => true, "nodeId" => node_id}}

          {:error, reason} ->
            {:error, {:internal_error, "Failed to set node policy", reason}}
        end

      true ->
        {:error, {:invalid_request, "policy or approvals is required", nil}}
    end
  end

  defp set_node_policy(node_id, policy) when is_map(policy) do
    # Store the node policy map for reference
    LemonCore.Store.put(:exec_approvals_policy_node_map, node_id, policy)

    # Also store per-tool entries that the runtime can check
    Enum.each(policy, fn {tool, disposition} ->
      if disposition == "allow" do
        # Store with node_id prefix and wildcard action hash
        LemonCore.Store.put(
          :exec_approvals_policy_node,
          {node_id, tool, :any},
          %{approved: true, scope: :node, node_id: node_id, approved_at_ms: LemonCore.Clock.now_ms()}
        )
      end
    end)

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp set_node_approvals(node_id, approvals) when is_list(approvals) do
    count =
      Enum.reduce(approvals, 0, fn approval, acc ->
        tool = approval["tool"]
        action = approval["action"] || %{}

        if tool do
          action_hash = hash_action(action)

          LemonCore.Store.put(
            :exec_approvals_policy_node,
            {node_id, tool, action_hash},
            %{
              approved: true,
              tool: tool,
              action_hash: action_hash,
              scope: :node,
              node_id: node_id,
              approved_at_ms: LemonCore.Clock.now_ms()
            }
          )

          acc + 1
        else
          acc
        end
      end)

    {:ok, count}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp hash_action(action) when is_map(action) and map_size(action) == 0, do: :any

  defp hash_action(action) when is_map(action) do
    :crypto.hash(:sha256, :erlang.term_to_binary(action))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp hash_action(_), do: :any
end
