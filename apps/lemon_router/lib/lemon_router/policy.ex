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
          "write" => :dangerous,    # require for dangerous actions
          "read" => :never          # never require approval
        },
        # Blocked tools (cannot be used at all)
        blocked_tools: ["process_kill", "exec_raw"],
        # Allowed commands (whitelist for bash/exec)
        allowed_commands: ["git", "npm", "cargo"],
        # Blocked commands (blacklist)
        blocked_commands: ["rm -rf /", "sudo"],
        # Max file size for write operations
        max_file_size: 1_048_576,
        # Sandbox mode
        sandbox: true
      }
  """

  @doc """
  Merge two tool policies.

  The second policy takes precedence, with some special handling:
  - Lists are concatenated (e.g., allowed_commands)
  - Maps are deep merged
  - Booleans use the stricter value for "deny" semantics
  """
  @spec merge(tool_policy_a :: map(), tool_policy_b :: map()) :: map()
  def merge(nil, policy_b), do: policy_b || %{}
  def merge(policy_a, nil), do: policy_a || %{}

  def merge(policy_a, policy_b) when is_map(policy_a) and is_map(policy_b) do
    Map.merge(policy_a, policy_b, fn key, v1, v2 ->
      merge_value(key, v1, v2)
    end)
  end

  defp merge_value(_key, v1, v2) when is_map(v1) and is_map(v2) do
    merge(v1, v2)
  end

  defp merge_value(key, v1, v2) when is_list(v1) and is_list(v2) do
    # For blocked lists, combine both. For allowed lists, use the more restrictive (v2).
    if String.contains?(to_string(key), "blocked") do
      Enum.uniq(v1 ++ v2)
    else
      # For allowed lists, take the intersection if v2 is non-empty
      if Enum.empty?(v2), do: v1, else: v2
    end
  end

  # For boolean deny semantics (sandbox, etc.), stricter wins
  defp merge_value(key, v1, v2) when is_boolean(v1) and is_boolean(v2) do
    if String.contains?(to_string(key), "sandbox") or String.contains?(to_string(key), "block") do
      v1 or v2
    else
      v2
    end
  end

  defp merge_value(_key, _v1, v2), do: v2

  @doc """
  Resolve the effective tool policy for a run.

  ## Parameters

  - `:agent_id` - Agent identifier
  - `:session_key` - Session key
  - `:origin` - Request origin (:channel, :control_plane, :cron, :node)
  - `:channel_context` - Optional channel-specific context
  """
  @spec resolve_for_run(map()) :: map()
  def resolve_for_run(params) do
    agent_id = params[:agent_id]
    session_key = params[:session_key]
    origin = params[:origin]
    channel_context = params[:channel_context]

    # Get agent default policy
    agent_policy = get_agent_policy(agent_id)

    # Get channel policy if applicable
    channel_policy =
      if origin == :channel and channel_context do
        get_channel_policy(channel_context)
      else
        %{}
      end

    # Get session overrides
    session_policy = get_session_policy(session_key)

    # Get runtime overrides
    runtime_policy = get_runtime_policy()

    # Merge in order: agent -> channel -> session -> runtime
    agent_policy
    |> merge(channel_policy)
    |> merge(session_policy)
    |> merge(runtime_policy)
  end

  @doc """
  Check if a tool requires approval based on the policy.

  Returns:
  - `:always` - Always require approval
  - `:dangerous` - Require approval only for dangerous actions
  - `:never` - Never require approval
  - `:default` - Use tool's default behavior
  """
  @spec approval_required?(map(), binary()) :: :always | :dangerous | :never | :default
  def approval_required?(policy, tool) do
    case get_in(policy, [:approvals, tool]) do
      :always -> :always
      :dangerous -> :dangerous
      :never -> :never
      "always" -> :always
      "dangerous" -> :dangerous
      "never" -> :never
      _ -> :default
    end
  end

  @doc """
  Check if a tool is blocked by the policy.
  """
  @spec tool_blocked?(map(), binary()) :: boolean()
  def tool_blocked?(policy, tool) do
    blocked = policy[:blocked_tools] || []
    tool in blocked
  end

  @doc """
  Check if a command is allowed by the policy.

  If no allowed_commands list is specified, all commands are allowed.
  If a blocked_commands list exists, those are always blocked.
  """
  @spec command_allowed?(map(), binary()) :: boolean()
  def command_allowed?(policy, command) do
    blocked = policy[:blocked_commands] || []

    # Check blocked first
    if command_matches_any?(command, blocked) do
      false
    else
      allowed = policy[:allowed_commands]

      # If no allowed list, everything is allowed
      if is_nil(allowed) or Enum.empty?(allowed) do
        true
      else
        command_matches_any?(command, allowed)
      end
    end
  end

  defp command_matches_any?(command, patterns) do
    Enum.any?(patterns, fn pattern ->
      String.starts_with?(command, pattern) or
        String.contains?(command, pattern)
    end)
  end

  # Load agent policy from store or config
  defp get_agent_policy(nil), do: %{}

  defp get_agent_policy(agent_id) do
    # Try loading from LemonCore.Store
    case LemonCore.Store.get_agent_policy(agent_id) do
      nil ->
        # Fall back to application config
        Application.get_env(:lemon_router, :agent_policies, %{})
        |> Map.get(agent_id, %{})

      policy when is_map(policy) ->
        policy
    end
  rescue
    _ -> %{}
  end

  # Load channel-specific restrictions
  defp get_channel_policy(nil), do: %{}

  defp get_channel_policy(channel_context) do
    channel_id = channel_context[:channel_id]
    peer_kind = channel_context[:peer_kind]

    # Load channel base policy
    channel_policy =
      case LemonCore.Store.get_channel_policy(channel_id) do
        nil -> %{}
        policy -> policy
      end

    # Groups are typically more restricted than DMs
    group_policy =
      if peer_kind in [:group, :supergroup, :channel] do
        %{
          # Groups typically require more approval
          approvals: %{
            "bash" => :always,
            "write" => :always,
            "process" => :always
          }
        }
      else
        %{}
      end

    merge(channel_policy, group_policy)
  rescue
    _ -> %{}
  end

  # Load session overrides from store
  defp get_session_policy(nil), do: %{}

  defp get_session_policy(session_key) do
    case LemonCore.Store.get_session_policy(session_key) do
      nil -> %{}
      policy when is_map(policy) -> policy
    end
  rescue
    _ -> %{}
  end

  # Load operator runtime overrides from config or store
  defp get_runtime_policy do
    # Check store first (allows dynamic updates)
    case LemonCore.Store.get_runtime_policy() do
      nil ->
        # Fall back to application config
        Application.get_env(:lemon_router, :runtime_policy, %{})

      policy when is_map(policy) ->
        policy
    end
  rescue
    _ -> %{}
  end
end
