defmodule LemonRouter.Policy do
  @moduledoc """
  Policy merging for tool execution.

  Merges tool policies from multiple sources:
  - Agent default policy
  - Channel policy (groups can be stricter)
  - Session overrides
  - Runtime overrides (operator)

  ## Policy Structure

  A tool policy is a map with the following optional keys:

      %{
        # Approval requirements per tool
        approvals: %{
          "bash" => :always,        # always require approval
          "write" => :dangerous,    # enforced like :always
          "read" => :never          # never require approval
        },
        # Blocked tools (cannot be used at all)
        blocked_tools: ["process_kill", "exec_raw"],
        # Allowed commands (whitelist for bash), enforced by
        # CodingAgent.Tools.Bash.CommandPolicy
        allowed_commands: ["git status", "npm test"],
        # Blocked commands (blacklist)
        blocked_commands: ["rm -rf", "sudo"],
        # Max file size for write operations
        max_file_size: 1_048_576
      }
  """

  alias LemonCore.ToolPolicy

  @doc """
  Intersect two operator-configured tool policy layers.

  The result cannot grant a tool or waive an approval gate that either layer
  applies; an unset `workspace_read_exempt` is neutral between layers. Invalid
  input returns a deny-all policy; execution admission uses `merge_validated/2`
  to retain the explicit validation error. Request overrides use
  `restrict_validated/2`.
  """
  @spec merge(term(), term()) :: ToolPolicy.t()
  def merge(policy_a, policy_b) do
    case merge_validated(policy_a, policy_b) do
      {:ok, policy} -> policy
      {:error, _reason} -> ToolPolicy.deny_all()
    end
  end

  @doc "Strict operator-layer intersection used by execution admission."
  @spec merge_validated(term(), term()) :: {:ok, ToolPolicy.t()} | {:error, term()}
  def merge_validated(policy_a, policy_b) do
    with {:ok, policy_a} <- resolve_layer(policy_a),
         {:ok, policy_b} <- resolve_layer(policy_b) do
      ToolPolicy.layer(policy_a, policy_b)
    end
  end

  @doc """
  Strictly narrows resolved operator authority with a request override.

  An absent override inherits `policy`; a supplied override can only narrow it
  and cannot enable a read exemption `policy` lacks.
  """
  @spec restrict_validated(term(), term()) :: {:ok, ToolPolicy.t()} | {:error, term()}
  def restrict_validated(policy, override) do
    with {:ok, policy} <- resolve_layer(policy),
         {:ok, override} <- ToolPolicy.resolve(override, policy) do
      ToolPolicy.restrict(policy, override)
    end
  end

  defp resolve_layer(policy),
    do: ToolPolicy.resolve(policy, ToolPolicy.from_profile(:full_access))

  @doc """
  Resolve the effective tool policy for a run.

  ## Parameters

  - `:agent_id` - Agent identifier
  - `:session_key` - Session key
  - `:channel_context` - Channel provenance (`meta.channel_context`). When it is
    present its channel policy and group approval floor apply whatever the
    submission origin; producers derive it from the authenticated ingress
    (channel transport, webhook integration, A2A peer).
  """
  @spec resolve_for_run(map()) :: ToolPolicy.t()
  def resolve_for_run(params) do
    case resolve_validated_for_run(params) do
      {:ok, policy} -> policy
      {:error, _reason} -> ToolPolicy.deny_all()
    end
  end

  @doc """
  Resolves all configured policy layers without permissive fallback.

  Every layer is read strictly: when the Store cannot confirm a layer's row
  (backend error, timeout or missing process) the result is
  `{:error, :policy_unavailable}`, never a policy without that layer.
  """
  @spec resolve_validated_for_run(map()) :: {:ok, ToolPolicy.t()} | {:error, term()}
  def resolve_validated_for_run(params) do
    agent_id = params[:agent_id]
    session_key = params[:session_key]
    channel_context = params[:channel_context]

    with {:ok, agent_policy} <- get_agent_policy(agent_id),
         {:ok, channel_policy} <- get_channel_policy(channel_context),
         {:ok, session_policy} <- get_session_policy(session_key),
         {:ok, runtime_policy} <- get_runtime_policy(),
         {:ok, policy} <- merge_validated(nil, agent_policy),
         {:ok, policy} <- merge_validated(policy, channel_policy),
         {:ok, policy} <- merge_validated(policy, session_policy) do
      merge_validated(policy, runtime_policy)
    end
  end

  @doc """
  Check if a tool requires approval based on the policy.

  Returns:
  - `:always` - Always require approval
  - `:dangerous` - Require approval (enforced like `:always`)
  - `:never` - Never require approval
  - `:default` - Use tool's default behavior
  """
  @spec approval_required?(map(), binary()) :: :always | :dangerous | :never | :default
  def approval_required?(policy, tool) do
    case ToolPolicy.approval_mode(policy, tool) do
      :always -> :always
      :dangerous -> :dangerous
      :never -> :never
      _ -> :default
    end
  end

  @doc """
  Check if a tool is blocked by the policy.
  """
  @spec tool_blocked?(map(), binary()) :: boolean()
  def tool_blocked?(policy, tool), do: not ToolPolicy.allowed?(policy, tool)

  # Load agent policy from store
  defp get_agent_policy(nil), do: {:ok, nil}

  defp get_agent_policy(agent_id), do: strict(LemonCore.PolicyStore.fetch_agent(agent_id))

  defp strict({:ok, _policy} = fetched), do: fetched
  defp strict({:error, _reason}), do: {:error, :policy_unavailable}

  # Tools that mutate files or execute code on the host. Group chats require
  # an approval for each call because any member can prompt the agent.
  @group_approval_tools ~w(bash write edit patch hashline_edit)

  # Load channel-specific restrictions named by the run's channel provenance.
  defp get_channel_policy(nil), do: {:ok, nil}

  defp get_channel_policy(channel_context) when is_map(channel_context) do
    channel_id = channel_context[:channel_id]
    peer_kind = channel_context[:peer_kind]

    # Fail closed: only an explicit DM escapes the group floor.
    group_policy =
      if peer_kind != :dm do
        %{approvals: Map.new(@group_approval_tools, &{&1, :always})}
      else
        %{}
      end

    with {:ok, channel_policy} <- strict(LemonCore.PolicyStore.fetch_channel(channel_id)) do
      merge_validated(channel_policy || %{}, group_policy)
    end
  end

  defp get_channel_policy(_invalid), do: {:error, :invalid_channel_context}

  # Session rows contain routing settings beside the nested policy. Legacy
  # top-level policy fields remain an additional floor, never an override.
  @policy_keys ~w(approvals approval_mode blocked_tools allowed_commands blocked_commands max_file_size profile allow deny require_approval no_reply)a

  defp get_session_policy(nil), do: {:ok, nil}

  defp get_session_policy(session_key) do
    case strict(LemonCore.PolicyStore.fetch_session(session_key)) do
      {:ok, nil} -> {:ok, nil}
      {:ok, policy} when is_map(policy) -> session_tool_policy(policy)
      {:ok, _invalid} -> {:error, :invalid_session_policy}
      {:error, _reason} = error -> error
    end
  end

  # Load operator runtime overrides from store
  defp get_runtime_policy, do: strict(LemonCore.PolicyStore.fetch_runtime())

  defp session_tool_policy(policy) do
    # Forward the removed key only so ToolPolicy can warn and discard it.
    legacy =
      Enum.reduce([:sandbox | @policy_keys], %{}, fn key, acc ->
        acc
        |> copy_present_policy_key(policy, key)
        |> copy_present_policy_key(policy, Atom.to_string(key))
      end)

    with {:ok, nested_policy} <- nested_session_tool_policy(policy) do
      merge_validated(legacy, nested_policy)
    end
  end

  defp nested_session_tool_policy(policy) do
    atom_value = Map.fetch(policy, :tool_policy)
    string_value = Map.fetch(policy, "tool_policy")

    case {atom_value, string_value} do
      {:error, :error} ->
        {:ok, nil}

      {{:ok, value}, :error} ->
        {:ok, value}

      {:error, {:ok, value}} ->
        {:ok, value}

      {{:ok, value}, {:ok, value}} ->
        {:ok, value}

      {{:ok, _atom_value}, {:ok, _string_value}} ->
        {:error, {:conflicting_session_policy_key, :tool_policy}}
    end
  end

  defp copy_present_policy_key(acc, source, key) do
    if is_map(source) and Map.has_key?(source, key) do
      Map.put(acc, key, Map.get(source, key))
    else
      acc
    end
  end
end
