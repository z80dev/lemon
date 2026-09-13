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

  alias LemonCore.ToolPolicy

  @doc """
  Intersect two tool policies.

  The result cannot authorize more than either input. Invalid input returns a
  deny-all policy; execution admission uses `merge_validated/2` to retain the
  explicit validation error.
  """
  @spec merge(term(), term()) :: ToolPolicy.t()
  def merge(policy_a, policy_b) do
    case merge_validated(policy_a, policy_b) do
      {:ok, policy} -> policy
      {:error, _reason} -> ToolPolicy.deny_all()
    end
  end

  @doc "Strict policy intersection used by execution admission."
  @spec merge_validated(term(), term()) :: {:ok, ToolPolicy.t()} | {:error, term()}
  def merge_validated(policy_a, policy_b) do
    with {:ok, policy_a} <-
           ToolPolicy.resolve(policy_a, ToolPolicy.from_profile(:full_access)),
         {:ok, policy_b} <-
           ToolPolicy.resolve(policy_b, ToolPolicy.from_profile(:full_access)) do
      ToolPolicy.restrict(policy_a, policy_b)
    end
  end

  @doc """
  Resolve the effective tool policy for a run.

  ## Parameters

  - `:agent_id` - Agent identifier
  - `:session_key` - Session key
  - `:origin` - Request origin (:channel, :control_plane, :cron, :node)
  - `:channel_context` - Optional channel-specific context
  """
  @spec resolve_for_run(map()) :: ToolPolicy.t()
  def resolve_for_run(params) do
    case resolve_validated_for_run(params) do
      {:ok, policy} -> policy
      {:error, _reason} -> ToolPolicy.deny_all()
    end
  end

  @doc "Resolves all configured policy layers without permissive fallback."
  @spec resolve_validated_for_run(map()) :: {:ok, ToolPolicy.t()} | {:error, term()}
  def resolve_validated_for_run(params) do
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

    # Get runtime overrides
    runtime_policy = get_runtime_policy()

    # Merge in order: agent -> channel -> session -> runtime
    with {:ok, session_policy} <- get_session_policy(session_key),
         {:ok, policy} <- merge_validated(nil, agent_policy),
         {:ok, policy} <- merge_validated(policy, channel_policy),
         {:ok, policy} <- merge_validated(policy, session_policy),
         {:ok, policy} <- merge_validated(policy, runtime_policy) do
      {:ok, policy}
    end
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

  @doc """
  Check if a command is allowed by the policy.

  If no allowed_commands list is specified, all commands are allowed.
  If a blocked_commands list exists, those are always blocked.
  """
  @spec command_allowed?(map(), binary()) :: boolean()
  def command_allowed?(policy, command) do
    case ToolPolicy.parse(policy) do
      {:ok, policy} ->
        not command_matches_any?(command, policy.blocked_commands) and
          (policy.allowed_commands == :all or
             command_matches_any?(command, policy.allowed_commands))

      {:error, _reason} ->
        false
    end
  end

  defp command_matches_any?(command, patterns) do
    Enum.any?(patterns, fn pattern ->
      String.starts_with?(command, pattern) or
        String.contains?(command, pattern)
    end)
  end

  # Load agent policy from store
  defp get_agent_policy(nil), do: nil

  defp get_agent_policy(agent_id) do
    case LemonCore.PolicyStore.get_agent(agent_id) do
      nil -> nil
      policy when is_map(policy) -> policy
    end
  rescue
    _ -> ToolPolicy.deny_all()
  end

  # Load channel-specific restrictions
  defp get_channel_policy(nil), do: %{}

  defp get_channel_policy(channel_context) do
    channel_id = channel_context[:channel_id]
    peer_kind = channel_context[:peer_kind]

    # Load channel base policy
    channel_policy =
      case LemonCore.PolicyStore.get_channel(channel_id) do
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
    _ -> ToolPolicy.deny_all()
  end

  # Load session overrides from store
  defp get_session_policy(nil), do: {:ok, nil}

  defp get_session_policy(session_key) do
    case LemonCore.PolicyStore.get_session(session_key) do
      nil -> {:ok, nil}
      policy when is_map(policy) -> session_tool_policy(policy)
    end
  rescue
    _ -> {:error, :session_policy_unavailable}
  end

  # Load operator runtime overrides from store
  defp get_runtime_policy do
    case LemonCore.PolicyStore.get_runtime() do
      nil -> nil
      policy when is_map(policy) -> policy
    end
  rescue
    _ -> ToolPolicy.deny_all()
  end

  defp session_tool_policy(policy) do
    keys = [
      :allow,
      :deny,
      :blocked_tools,
      :require_approval,
      :approvals,
      :no_reply,
      :profile,
      :allowed_commands,
      :blocked_commands,
      :max_file_size,
      :sandbox
    ]

    with {:ok, nested_policy} <- nested_session_tool_policy(policy) do
      source = if is_nil(nested_policy), do: policy, else: nested_policy

      if is_map(source) do
        selected =
          Enum.reduce(keys, %{}, fn key, acc ->
            acc
            |> copy_present_policy_key(source, key)
            |> copy_present_policy_key(source, Atom.to_string(key))
          end)

        {:ok, if(map_size(selected) == 0, do: nil, else: selected)}
      else
        {:ok, source}
      end
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
