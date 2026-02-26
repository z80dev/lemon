defmodule LemonControlPlane.Methods.ExecApprovalsSet do
  @moduledoc """
  Handler for the exec.approvals.set method.

  Sets global tool approval policies. Supports two modes:

  ## Policy Mode
  Sets which tools require approval:
  ```json
  {"policy": {"bash": "require", "write": "require", "edit": "allow"}}
  ```

  ## Pre-approval Mode
  Pre-approves specific tool+action combinations:
  ```json
  {"approvals": [{"tool": "bash", "action": {"command": "npm test"}}]}
  ```
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "exec.approvals.set"

  @impl true
  def scopes, do: [:admin, :approvals]

  @impl true
  def handle(params, _ctx) do
    policy = params["policy"]
    approvals = params["approvals"]

    cond do
      not is_nil(approvals) ->
        # Pre-approval mode: store specific tool+action approvals
        case set_approvals(approvals) do
          {:ok, count} ->
            {:ok, %{"success" => true, "approvals_set" => count}}

          {:error, reason} ->
            {:error, {:internal_error, "Failed to set approvals", reason}}
        end

      not is_nil(policy) ->
        # Policy mode: store tool-level policy and also pre-approve "allow" tools
        case set_approval_policy(policy) do
          :ok ->
            {:ok, %{"success" => true}}

          {:error, reason} ->
            {:error, {:internal_error, "Failed to set policy", reason}}
        end

      true ->
        {:error, {:invalid_request, "policy or approvals is required", nil}}
    end
  end

  defp set_approval_policy(policy) when is_map(policy) do
    # Store the global policy map for reference
    LemonCore.Store.put(:exec_approvals_policy_map, :global, policy)

    # Also store per-tool entries that the runtime can check
    # Tools with "allow" are pre-approved at the tool level (any action)
    Enum.each(policy, fn {tool, disposition} ->
      if disposition == "allow" do
        # Store with a wildcard action hash to indicate any action is pre-approved
        LemonCore.Store.put(
          :exec_approvals_policy,
          {tool, :any},
          %{approved: true, scope: :global, approved_at_ms: LemonCore.Clock.now_ms()}
        )
      end
    end)

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp set_approvals(approvals) when is_list(approvals) do
    count =
      Enum.reduce(approvals, 0, fn approval, acc ->
        tool = approval["tool"]
        action = approval["action"] || %{}

        if tool do
          action_hash = hash_action(action)

          LemonCore.Store.put(
            :exec_approvals_policy,
            {tool, action_hash},
            %{
              approved: true,
              tool: tool,
              action_hash: action_hash,
              scope: :global,
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
