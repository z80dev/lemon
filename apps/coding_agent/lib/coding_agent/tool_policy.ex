defmodule CodingAgent.ToolPolicy do
  @moduledoc """
  Per-agent tool policy profiles for access control.

  Provides allow/deny lists for tools, per-engine restrictions,
  approval gates for dangerous operations, and NO_REPLY support.

  ## Policy Profiles

  Predefined profiles:
  - `:full_access` - All tools allowed
  - `:read_only` - Only read/search tools
  - `:safe_mode` - No write/exec/bash tools
  - `:subagent_restricted` - Subagent can't run dangerous tools
  - `:no_external` - No web fetch/search

  ## Usage

      # Create policy from profile
      policy = ToolPolicy.from_profile(:safe_mode)

      # Check if tool is allowed
      ToolPolicy.allowed?(policy, "write")

      # Apply policy to tools list
      allowed_tools = ToolPolicy.apply_policy(policy, all_tools)
  """

  @type policy :: %{
          allow: :all | [String.t()],
          deny: [String.t()],
          require_approval: [String.t()],
          no_reply: boolean(),
          profile: atom() | nil
        }

  @type profile ::
          :full_access
          | :read_only
          | :safe_mode
          | :subagent_restricted
          | :no_external
          | :custom

  @read_tools ["read", "grep", "find", "glob", "ls", "todoread"]

  @external_tools ["webfetch", "websearch"]

  @dangerous_tools ["write", "edit", "multiedit", "patch", "bash", "exec", "process"]

  # ============================================================================
  # Profile Creation
  # ============================================================================

  @doc """
  Create a policy from a predefined profile.

  ## Profiles

  - `:full_access` - All tools allowed (default)
  - `:read_only` - Only read/search tools allowed
  - `:safe_mode` - No write/exec/bash tools allowed
  - `:subagent_restricted` - Subagent with no dangerous tools
  - `:no_external` - No web fetch/search allowed
  """
  @spec from_profile(profile()) :: policy()
  def from_profile(:full_access) do
    %{
      allow: :all,
      deny: [],
      require_approval: [],
      no_reply: false,
      profile: :full_access
    }
  end

  def from_profile(:read_only) do
    %{
      allow: @read_tools,
      deny: [],
      require_approval: [],
      no_reply: false,
      profile: :read_only
    }
  end

  def from_profile(:safe_mode) do
    %{
      allow: :all,
      deny: @dangerous_tools,
      require_approval: [],
      no_reply: false,
      profile: :safe_mode
    }
  end

  def from_profile(:subagent_restricted) do
    %{
      allow: :all,
      deny: @dangerous_tools,
      require_approval: ["write", "edit"],
      no_reply: false,
      profile: :subagent_restricted
    }
  end

  def from_profile(:no_external) do
    %{
      allow: :all,
      deny: @external_tools,
      require_approval: [],
      no_reply: false,
      profile: :no_external
    }
  end

  def from_profile(:custom) do
    %{
      allow: :all,
      deny: [],
      require_approval: [],
      no_reply: false,
      profile: :custom
    }
  end

  def from_profile(_), do: from_profile(:full_access)

  @doc """
  Create a custom policy.

  ## Options

  - `:allow` - List of allowed tools or :all
  - `:deny` - List of denied tools
  - `:require_approval` - List of tools requiring approval
  - `:no_reply` - Enable NO_REPLY mode
  """
  @spec custom(keyword()) :: policy()
  def custom(opts \\ []) do
    %{
      allow: Keyword.get(opts, :allow, :all),
      deny: Keyword.get(opts, :deny, []),
      require_approval: Keyword.get(opts, :require_approval, []),
      no_reply: Keyword.get(opts, :no_reply, false),
      profile: :custom
    }
  end

  # ============================================================================
  # Policy Checking
  # ============================================================================

  @doc """
  Check if a tool is allowed by the policy.

  ## Examples

      policy = ToolPolicy.from_profile(:read_only)
      ToolPolicy.allowed?(policy, "read")  # => true
      ToolPolicy.allowed?(policy, "write") # => false
  """
  @spec allowed?(policy(), String.t()) :: boolean()
  def allowed?(%{allow: :all, deny: deny}, tool_name) do
    tool_name not in deny
  end

  def allowed?(%{allow: allowed, deny: deny}, tool_name) do
    tool_name in allowed and tool_name not in deny
  end

  @doc """
  Check if a tool requires approval.

  Returns false for empty or incomplete policies that don't have
  a `require_approval` key.
  """
  @spec requires_approval?(policy() | map(), String.t()) :: boolean()
  def requires_approval?(%{require_approval: approval_list}, tool_name)
      when is_list(approval_list) do
    tool_name in approval_list
  end

  def requires_approval?(_, _tool_name), do: false

  @doc """
  Check if NO_REPLY mode is enabled.
  """
  @spec no_reply?(policy()) :: boolean()
  def no_reply?(%{no_reply: no_reply}), do: no_reply

  @doc """
  Get the reason a tool is denied.
  """
  @spec denial_reason(policy(), String.t()) :: String.t() | nil
  def denial_reason(%{allow: allowed, deny: denied}, tool_name) do
    cond do
      tool_name in denied ->
        "Tool '#{tool_name}' is in deny list"

      allowed != :all and tool_name not in allowed ->
        "Tool '#{tool_name}' not in allowed list"

      true ->
        nil
    end
  end

  # ============================================================================
  # Policy Application
  # ============================================================================

  @doc """
  Apply a policy to a list of tools.

  Returns only the tools allowed by the policy.

  ## Examples

      tools = [read_tool, write_tool, bash_tool]
      policy = ToolPolicy.from_profile(:read_only)
      allowed = ToolPolicy.apply_policy(policy, tools)
      # => [read_tool]
  """
  @spec apply_policy(policy(), [AgentCore.Types.AgentTool.t()]) :: [
          AgentCore.Types.AgentTool.t()
        ]
  def apply_policy(policy, tools) do
    Enum.filter(tools, fn tool ->
      allowed?(policy, tool.name)
    end)
  end

  @doc """
  Apply policy and return both allowed and denied tools.

  Returns `{allowed_tools, denied_tools}` tuple.
  """
  @spec partition_tools(policy(), [AgentCore.Types.AgentTool.t()]) :: {
          [AgentCore.Types.AgentTool.t()],
          [AgentCore.Types.AgentTool.t()]
        }
  def partition_tools(policy, tools) do
    Enum.split_with(tools, fn tool ->
      allowed?(policy, tool.name)
    end)
  end

  @doc """
  Apply policy to a tools map.

  Returns a filtered map with only allowed tools.
  """
  @spec apply_policy_to_map(policy(), %{String.t() => AgentCore.Types.AgentTool.t()}) :: %{
          String.t() => AgentCore.Types.AgentTool.t()
        }
  def apply_policy_to_map(policy, tools_map) do
    Map.filter(tools_map, fn {name, _tool} ->
      allowed?(policy, name)
    end)
  end

  # ============================================================================
  # Engine-Specific Policies
  # ============================================================================

  @doc """
  Get the default policy for an engine.

  Different engines have different default restrictions:
  - `:internal` - Full access
  - `:codex` - Subagent restricted (can't run dangerous tools)
  - `:claude` - Subagent restricted
  - `:kimi` - Subagent restricted
  """
  @spec engine_policy(atom()) :: policy()
  def engine_policy(:internal), do: from_profile(:full_access)
  def engine_policy(:codex), do: from_profile(:subagent_restricted)
  def engine_policy(:claude), do: from_profile(:subagent_restricted)
  def engine_policy(:kimi), do: from_profile(:subagent_restricted)
  def engine_policy(:opencode), do: from_profile(:subagent_restricted)
  def engine_policy(:pi), do: from_profile(:subagent_restricted)
  def engine_policy(_), do: from_profile(:full_access)

  @doc """
  Create a policy for a subagent based on engine type.
  """
  @spec subagent_policy(atom(), keyword()) :: policy()
  def subagent_policy(engine, opts \\ []) do
    base_policy = engine_policy(engine)

    # Merge with any custom restrictions
    custom_allow = Keyword.get(opts, :allow)
    custom_deny = Keyword.get(opts, :deny, [])
    custom_approval = Keyword.get(opts, :require_approval, [])
    no_reply = Keyword.get(opts, :no_reply, false)

    %{
      base_policy
      | allow: custom_allow || base_policy.allow,
        deny: base_policy.deny ++ custom_deny,
        require_approval: base_policy.require_approval ++ custom_approval,
        no_reply: no_reply || base_policy.no_reply
    }
  end

  # ============================================================================
  # Policy Serialization
  # ============================================================================

  @doc """
  Convert policy to a map for storage/transmission.
  """
  @spec to_map(policy()) :: map()
  def to_map(policy) do
    %{
      "allow" =>
        case policy.allow do
          :all -> "all"
          list -> list
        end,
      "deny" => policy.deny,
      "require_approval" => policy.require_approval,
      "no_reply" => policy.no_reply,
      "profile" =>
        case Map.get(policy, :profile) do
          nil -> nil
          atom -> Atom.to_string(atom)
        end
    }
  end

  @doc """
  Parse policy from a map.
  """
  @spec from_map(map()) :: policy()
  def from_map(map) do
    %{
      allow:
        case map["allow"] do
          "all" -> :all
          list when is_list(list) -> list
          _ -> :all
        end,
      deny: Map.get(map, "deny", []),
      require_approval: Map.get(map, "require_approval", []),
      no_reply: Map.get(map, "no_reply", false),
      profile:
        case Map.get(map, "profile") do
          nil -> nil
          str -> String.to_existing_atom(str)
        end
    }
  end

  # ============================================================================
  # NO_REPLY Support
  # ============================================================================

  @doc """
  Mark a message as NO_REPLY.

  NO_REPLY messages are processed but don't generate responses.
  Useful for background work and silent operations.

  ## Options

  - `:reason` - Reason for NO_REPLY (e.g., "background_task", "compaction")
  """
  @spec mark_no_reply(map(), keyword()) :: map()
  def mark_no_reply(message, opts \\ []) do
    reason = Keyword.get(opts, :reason, "silent")

    message
    |> Map.put(:no_reply, true)
    |> Map.put(:no_reply_reason, reason)
  end

  @doc """
  Check if a message has NO_REPLY flag.
  """
  @spec message_no_reply?(map()) :: boolean()
  def message_no_reply?(message) do
    Map.get(message, :no_reply, false) or Map.get(message, "no_reply", false)
  end

  @doc """
  Filter NO_REPLY messages from a list.

  Returns `{normal_messages, no_reply_messages}`.
  """
  @spec filter_no_reply([map()]) :: {[map()], [map()]}
  def filter_no_reply(messages) do
    Enum.split_with(messages, fn msg ->
      not message_no_reply?(msg)
    end)
  end
end
