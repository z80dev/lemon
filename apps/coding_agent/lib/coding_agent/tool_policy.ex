defmodule CodingAgent.ToolPolicy do
  @moduledoc """
  Per-agent tool policy profiles for access control.

  Provides allow/deny lists for tools, per-engine restrictions,
  approval gates for dangerous operations, and NO_REPLY support.
  """

  @type approval_mode :: :always | :never

  @type policy :: %{
          allow: :all | [String.t()],
          deny: [String.t()],
          require_approval: [String.t()],
          approvals: %{optional(String.t()) => approval_mode()},
          no_reply: boolean(),
          profile: atom() | nil
        }

  @type profile ::
          :full_access
          | :minimal_core
          | :read_only
          | :safe_mode
          | :subagent_restricted
          | :no_external
          | :custom

  @read_tools ["read", "grep", "find", "ls"]

  @minimal_core_tools [
    "read",
    "memory_topic",
    "write",
    "edit",
    "patch",
    "bash",
    "grep",
    "find",
    "ls",
    "browser",
    "webfetch",
    "websearch",
    "todo",
    "task",
    "agent",
    "extensions_status"
  ]

  @external_tools ["browser", "webfetch", "websearch"]

  @dangerous_tools ["write", "edit", "patch", "bash", "exec", "process", "agent"]

  # ============================================================================
  # Profile Creation
  # ============================================================================

  @doc """
  Create a policy from a predefined profile.
  """
  @spec from_profile(profile()) :: policy()
  def from_profile(:full_access) do
    %{
      allow: :all,
      deny: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: :full_access
    }
  end

  def from_profile(:minimal_core) do
    %{
      allow: @minimal_core_tools,
      deny: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: :minimal_core
    }
  end

  def from_profile(:read_only) do
    %{
      allow: @read_tools,
      deny: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: :read_only
    }
  end

  def from_profile(:safe_mode) do
    %{
      allow: :all,
      deny: @dangerous_tools,
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: :safe_mode
    }
  end

  def from_profile(:subagent_restricted) do
    %{
      allow: :all,
      deny: @dangerous_tools,
      require_approval: ["write", "edit"],
      approvals: %{},
      no_reply: false,
      profile: :subagent_restricted
    }
  end

  def from_profile(:no_external) do
    %{
      allow: :all,
      deny: @external_tools,
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: :no_external
    }
  end

  def from_profile(:custom) do
    %{
      allow: :all,
      deny: [],
      require_approval: [],
      approvals: %{},
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
  - `:approvals` - Router-style explicit approvals map (tool => always|never)
  - `:no_reply` - Enable NO_REPLY mode
  """
  @spec custom(keyword()) :: policy()
  def custom(opts \\ []) do
    %{
      allow: Keyword.get(opts, :allow, :all),
      deny: Keyword.get(opts, :deny, []),
      require_approval: Keyword.get(opts, :require_approval, []),
      approvals: normalize_approvals(Keyword.get(opts, :approvals, %{})),
      no_reply: Keyword.get(opts, :no_reply, false),
      profile: :custom
    }
  end

  # ============================================================================
  # Policy Checking
  # ============================================================================

  @doc """
  Check if a tool is allowed by the policy.
  """
  @spec allowed?(policy() | map(), String.t()) :: boolean()
  def allowed?(policy, tool_name) when is_map(policy) and is_binary(tool_name) do
    allow = normalize_allow(Map.get(policy, :allow) || Map.get(policy, "allow"))
    deny = normalize_string_list(Map.get(policy, :deny) || Map.get(policy, "deny"))

    cond do
      allow == :all ->
        tool_name not in deny

      is_list(allow) ->
        tool_name in allow and tool_name not in deny

      true ->
        false
    end
  end

  def allowed?(_, _), do: true

  @doc """
  Check if a tool requires approval.

  Supports both legacy `require_approval` lists and router-style `approvals` maps.
  """
  @spec requires_approval?(policy() | map(), String.t()) :: boolean()
  def requires_approval?(policy, tool_name) when is_map(policy) and is_binary(tool_name) do
    require_approval =
      normalize_string_list(
        Map.get(policy, :require_approval) || Map.get(policy, "require_approval")
      )

    cond do
      tool_name in require_approval ->
        true

      approval_mode(policy, tool_name) == :always ->
        true

      true ->
        false
    end
  end

  def requires_approval?(_, _tool_name), do: false

  @doc """
  Resolve explicit approval mode for a tool from router-style approvals maps.
  """
  @spec approval_mode(policy() | map(), String.t()) :: :always | :never | :inherit
  def approval_mode(policy, tool_name) when is_map(policy) and is_binary(tool_name) do
    approvals = normalize_approvals(Map.get(policy, :approvals) || Map.get(policy, "approvals"))

    case Map.get(approvals, tool_name) do
      :always -> :always
      :never -> :never
      _ -> :inherit
    end
  end

  def approval_mode(_, _tool_name), do: :inherit

  @doc """
  Check if NO_REPLY mode is enabled.
  """
  @spec no_reply?(policy()) :: boolean()
  def no_reply?(%{no_reply: no_reply}), do: no_reply

  @doc """
  Get the reason a tool is denied.
  """
  @spec denial_reason(policy() | map(), String.t()) :: String.t() | nil
  def denial_reason(policy, tool_name) when is_map(policy) and is_binary(tool_name) do
    allowed = normalize_allow(Map.get(policy, :allow) || Map.get(policy, "allow"))
    denied = normalize_string_list(Map.get(policy, :deny) || Map.get(policy, "deny"))

    cond do
      tool_name in denied ->
        "Tool '#{tool_name}' is in deny list"

      allowed != :all and tool_name not in allowed ->
        "Tool '#{tool_name}' not in allowed list"

      true ->
        nil
    end
  end

  def denial_reason(_, _), do: nil

  # ============================================================================
  # Policy Application
  # ============================================================================

  @doc """
  Apply a policy to a list of tools.
  """
  @spec apply_policy(policy() | map(), [AgentCore.Types.AgentTool.t()]) :: [
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
  @spec partition_tools(policy() | map(), [AgentCore.Types.AgentTool.t()]) :: {
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
  @spec apply_policy_to_map(policy() | map(), %{String.t() => AgentCore.Types.AgentTool.t()}) ::
          %{
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

    custom_allow = Keyword.get(opts, :allow)
    custom_deny = Keyword.get(opts, :deny, [])
    custom_approval = Keyword.get(opts, :require_approval, [])
    custom_approvals = normalize_approvals(Keyword.get(opts, :approvals, %{}))
    no_reply = Keyword.get(opts, :no_reply, false)

    %{
      base_policy
      | allow: custom_allow || base_policy.allow,
        deny: base_policy.deny ++ custom_deny,
        require_approval: base_policy.require_approval ++ custom_approval,
        approvals: Map.merge(base_policy.approvals, custom_approvals),
        no_reply: no_reply || base_policy.no_reply
    }
  end

  # ============================================================================
  # Policy Serialization
  # ============================================================================

  @doc """
  Convert policy to a map for storage/transmission.
  """
  @spec to_map(policy() | map()) :: map()
  def to_map(policy) do
    allow = normalize_allow(Map.get(policy, :allow) || Map.get(policy, "allow"))
    deny = normalize_string_list(Map.get(policy, :deny) || Map.get(policy, "deny"))

    require_approval =
      normalize_string_list(
        Map.get(policy, :require_approval) || Map.get(policy, "require_approval")
      )

    approvals = normalize_approvals(Map.get(policy, :approvals) || Map.get(policy, "approvals"))

    %{
      "allow" =>
        case allow do
          :all -> "all"
          list -> list
        end,
      "deny" => deny,
      "require_approval" => require_approval,
      "approvals" =>
        approvals
        |> Enum.into(%{}, fn {tool, mode} -> {tool, Atom.to_string(mode)} end),
      "no_reply" => Map.get(policy, :no_reply) || Map.get(policy, "no_reply") || false,
      "profile" =>
        case Map.get(policy, :profile) || Map.get(policy, "profile") do
          nil -> nil
          atom when is_atom(atom) -> Atom.to_string(atom)
          str when is_binary(str) -> str
          _ -> nil
        end
    }
  end

  @doc """
  Parse policy from a map.
  """
  @spec from_map(map()) :: policy()
  def from_map(map) do
    %{
      allow: normalize_allow(Map.get(map, "allow") || Map.get(map, :allow)),
      deny: normalize_string_list(Map.get(map, "deny") || Map.get(map, :deny)),
      require_approval:
        normalize_string_list(Map.get(map, "require_approval") || Map.get(map, :require_approval)),
      approvals: normalize_approvals(Map.get(map, "approvals") || Map.get(map, :approvals)),
      no_reply: Map.get(map, "no_reply") || Map.get(map, :no_reply) || false,
      profile:
        case Map.get(map, "profile") || Map.get(map, :profile) do
          nil -> nil
          atom when is_atom(atom) -> atom
          "full_access" -> :full_access
          "minimal_core" -> :minimal_core
          "read_only" -> :read_only
          "safe_mode" -> :safe_mode
          "subagent_restricted" -> :subagent_restricted
          "no_external" -> :no_external
          "custom" -> :custom
          str when is_binary(str) -> if(String.trim(str) == "", do: nil, else: nil)
          _ -> nil
        end
    }
  end

  # ============================================================================
  # NO_REPLY Support
  # ============================================================================

  @doc """
  Mark a message as NO_REPLY.
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

  defp normalize_allow(nil), do: :all
  defp normalize_allow(:all), do: :all
  defp normalize_allow("all"), do: :all

  defp normalize_allow(value) when is_binary(value) do
    [String.trim(value)]
  end

  defp normalize_allow(value) when is_list(value) do
    normalize_string_list(value)
  end

  defp normalize_allow(_), do: :all

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(value) when is_binary(value) do
    [String.trim(value)]
  end

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(fn
      v when is_binary(v) -> String.trim(v)
      v when is_atom(v) -> v |> Atom.to_string() |> String.trim()
      v -> v |> to_string() |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_), do: []

  defp normalize_approvals(nil), do: %{}

  defp normalize_approvals(approvals) when is_map(approvals) do
    approvals
    |> Enum.reduce(%{}, fn {tool, mode}, acc ->
      tool_name = tool |> to_string() |> String.trim()

      case normalize_approval_mode(mode) do
        nil -> acc
        _ when tool_name == "" -> acc
        normalized -> Map.put(acc, tool_name, normalized)
      end
    end)
  end

  defp normalize_approvals(_), do: %{}

  defp normalize_approval_mode(:always), do: :always
  defp normalize_approval_mode("always"), do: :always
  defp normalize_approval_mode(true), do: :always
  defp normalize_approval_mode(:required), do: :always
  defp normalize_approval_mode("required"), do: :always

  defp normalize_approval_mode(:never), do: :never
  defp normalize_approval_mode("never"), do: :never
  defp normalize_approval_mode(false), do: :never
  defp normalize_approval_mode(:none), do: :never
  defp normalize_approval_mode("none"), do: :never

  defp normalize_approval_mode(%{"mode" => mode}), do: normalize_approval_mode(mode)
  defp normalize_approval_mode(%{mode: mode}), do: normalize_approval_mode(mode)

  defp normalize_approval_mode(_), do: nil
end
