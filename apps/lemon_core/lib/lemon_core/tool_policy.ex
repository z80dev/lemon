defmodule LemonCore.ToolPolicy do
  @moduledoc """
  Canonical, validated authorization policy for Lemon tool execution.

  Policies cross process and network boundaries only as this struct. Use
  `parse/1` for untrusted atom- or string-keyed input; malformed input is
  rejected instead of being normalized to full access.

  `restrict/2` computes the intersection of two policies. It is used for
  delegated work so a child request cannot remove a parent denial or approval
  requirement.
  """

  @type approval_mode :: :always | :dangerous | :never
  @type profile ::
          :full_access
          | :orchestrator
          | :leaf_worker
          | :minimal_core
          | :read_only
          | :safe_mode
          | :subagent_restricted
          | :no_external
          | :custom

  @type t :: %__MODULE__{
          allow: :all | [String.t()],
          deny: [String.t()],
          blocked_tools: [String.t()],
          require_approval: [String.t()],
          approvals: %{optional(String.t()) => approval_mode()},
          no_reply: boolean(),
          profile: profile() | nil,
          allowed_commands: :all | [String.t()],
          blocked_commands: [String.t()],
          max_file_size: pos_integer() | nil,
          sandbox: boolean()
        }

  @enforce_keys [
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
  defstruct @enforce_keys

  @profiles [
    :full_access,
    :orchestrator,
    :leaf_worker,
    :minimal_core,
    :read_only,
    :safe_mode,
    :subagent_restricted,
    :no_external,
    :custom
  ]

  @policy_keys [
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

  @read_tools ["read", "read_skill", "search_memory", "session_search", "grep", "find", "ls"]

  @minimal_core_tools [
    "read",
    "read_skill",
    "search_memory",
    "skill_manage",
    "memory_topic",
    "memory",
    "checkpoint",
    "session_search",
    "write",
    "edit",
    "patch",
    "bash",
    "execute_code",
    "grep",
    "find",
    "ls",
    "webfetch",
    "websearch",
    "browser_navigate",
    "browser_snapshot",
    "browser_get_content",
    "browser_click",
    "browser_type",
    "browser_hover",
    "browser_select_option",
    "browser_upload_file",
    "browser_download",
    "browser_press",
    "browser_scroll",
    "browser_back",
    "browser_wait_for_selector",
    "browser_evaluate",
    "browser_events",
    "browser_get_cookies",
    "browser_set_cookies",
    "browser_clear_state",
    "browser_screenshot",
    "browser_analyze",
    "browser_exec",
    "computer_use",
    "media_status",
    "media_generate_image",
    "media_generate_speech",
    "media_transcribe_audio",
    "media_analyze_image",
    "media_generate_video",
    "todo",
    "kanban",
    "task",
    "agent",
    "extensions_status"
  ]

  @external_tools [
    "webfetch",
    "websearch",
    "browser_navigate",
    "browser_snapshot",
    "browser_get_content",
    "browser_click",
    "browser_type",
    "browser_hover",
    "browser_select_option",
    "browser_upload_file",
    "browser_download",
    "browser_press",
    "browser_scroll",
    "browser_back",
    "browser_wait_for_selector",
    "browser_evaluate",
    "browser_events",
    "browser_get_cookies",
    "browser_set_cookies",
    "browser_clear_state",
    "browser_screenshot",
    "browser_analyze",
    "browser_exec",
    "computer_use",
    "media_status",
    "media_generate_image",
    "media_generate_speech",
    "media_transcribe_audio",
    "media_analyze_image",
    "media_generate_video"
  ]

  @dangerous_tools [
    "write",
    "edit",
    "hashline_edit",
    "patch",
    "checkpoint",
    "skill_manage",
    "memory",
    "memory_topic",
    "bash",
    "execute_code",
    "exec",
    "process",
    "agent",
    "task",
    "browser_click",
    "browser_type",
    "browser_select_option",
    "browser_upload_file",
    "browser_download",
    "browser_press",
    "browser_set_cookies",
    "browser_clear_state",
    "browser_evaluate",
    "browser_screenshot",
    "browser_analyze",
    "browser_exec",
    "computer_use",
    "media_generate_image",
    "media_generate_speech",
    "media_transcribe_audio",
    "media_analyze_image",
    "media_generate_video"
  ]

  @doc "Returns a validated predefined policy; unknown profiles deny every tool."
  @spec from_profile(term()) :: t()
  def from_profile(profile) do
    case fetch_profile(profile) do
      {:ok, policy} -> policy
      {:error, _reason} -> deny_all()
    end
  end

  @doc "Returns a validated predefined policy or an explicit validation error."
  @spec fetch_profile(term()) :: {:ok, t()} | {:error, term()}
  def fetch_profile(profile) when is_binary(profile) do
    normalized = String.trim(profile)

    case Enum.find(@profiles, &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, {:unknown_policy_profile, profile}}
      known -> {:ok, profile_policy(known)}
    end
  end

  def fetch_profile(profile) when profile in @profiles, do: {:ok, profile_policy(profile)}
  def fetch_profile(profile), do: {:error, {:unknown_policy_profile, profile}}

  @doc "Builds a validated custom policy and raises on invalid trusted input."
  @spec custom(keyword()) :: t()
  def custom(opts \\ []) when is_list(opts) do
    opts
    |> Enum.into(%{})
    |> Map.put_new(:profile, :custom)
    |> parse!()
  end

  @doc """
  Strictly parses untrusted policy input.

  `nil` is reported as absent so callers can choose an explicit default.
  Unknown keys, conflicting atom/string keys, malformed lists, unknown
  profiles, and unsupported approval modes are rejected.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, term()}
  def parse(nil), do: {:error, :policy_absent}

  def parse(%__MODULE__{} = policy) do
    policy
    |> Map.from_struct()
    |> parse_map()
  end

  def parse(profile) when is_atom(profile) or is_binary(profile), do: fetch_profile(profile)
  def parse(policy) when is_map(policy), do: parse_map(policy)
  def parse(_policy), do: {:error, :invalid_tool_policy}

  @doc "Strict parse variant for trusted constructors."
  @spec parse!(term()) :: t()
  def parse!(policy) do
    case parse(policy) do
      {:ok, validated} -> validated
      {:error, reason} -> raise ArgumentError, "invalid tool policy: #{inspect(reason)}"
    end
  end

  @doc "Returns true only for a policy struct that still passes validation."
  @spec validated?(term()) :: boolean()
  def validated?(%__MODULE__{} = policy), do: match?({:ok, _}, parse(policy))
  def validated?(_policy), do: false

  @doc """
  Resolve an optional policy using an explicit trusted default.

  Invalid supplied input is never treated as absent.
  """
  @spec resolve(term(), t()) :: {:ok, t()} | {:error, term()}
  def resolve(nil, %__MODULE__{} = default), do: {:ok, default}
  def resolve(policy, %__MODULE__{}), do: parse(policy)

  @doc "Intersect parent and requested authority without broadening either."
  @spec restrict(t() | map(), t() | map()) :: {:ok, t()} | {:error, term()}
  def restrict(parent, requested) do
    with {:ok, parent} <- parse(parent),
         {:ok, requested} <- parse(requested) do
      {:ok,
       %__MODULE__{
         allow: intersect_allow(parent.allow, requested.allow),
         deny: union(parent.deny, requested.deny),
         blocked_tools: union(parent.blocked_tools, requested.blocked_tools),
         require_approval: union(parent.require_approval, requested.require_approval),
         approvals: merge_approvals(parent.approvals, requested.approvals),
         no_reply: parent.no_reply or requested.no_reply,
         profile: :custom,
         allowed_commands: intersect_allow(parent.allowed_commands, requested.allowed_commands),
         blocked_commands: union(parent.blocked_commands, requested.blocked_commands),
         max_file_size: minimum_limit(parent.max_file_size, requested.max_file_size),
         sandbox: parent.sandbox or requested.sandbox
       }}
    end
  end

  @doc "Checks whether a tool is authorized. Invalid input fails closed."
  @spec allowed?(t() | map(), String.t()) :: boolean()
  def allowed?(policy, tool_name) when is_binary(tool_name) do
    case parse(policy) do
      {:ok, policy} ->
        tool_name not in policy.blocked_tools and tool_name not in policy.deny and
          (policy.allow == :all or tool_name in policy.allow)

      {:error, _reason} ->
        false
    end
  end

  def allowed?(_policy, _tool_name), do: false

  @doc "Checks whether a tool requires approval. Invalid input requires approval."
  @spec requires_approval?(t() | map(), String.t()) :: boolean()
  def requires_approval?(policy, tool_name) when is_binary(tool_name) do
    case parse(policy) do
      {:ok, policy} ->
        tool_name in policy.require_approval or
          Map.get(policy.approvals, tool_name) in [:always, :dangerous]

      {:error, _reason} ->
        true
    end
  end

  def requires_approval?(_policy, _tool_name), do: true

  @doc "Returns the explicit approval mode for a tool."
  @spec approval_mode(t() | map(), String.t()) :: approval_mode() | :inherit
  def approval_mode(policy, tool_name) when is_binary(tool_name) do
    case parse(policy) do
      {:ok, policy} -> Map.get(policy.approvals, tool_name, :inherit)
      {:error, _reason} -> :always
    end
  end

  def approval_mode(_policy, _tool_name), do: :always

  @doc "Checks whether NO_REPLY mode is enabled."
  @spec no_reply?(t() | map()) :: boolean()
  def no_reply?(policy) do
    case parse(policy) do
      {:ok, policy} -> policy.no_reply
      {:error, _reason} -> false
    end
  end

  @doc "Returns a safe explanation when a tool is denied."
  @spec denial_reason(t() | map(), String.t()) :: String.t() | nil
  def denial_reason(policy, tool_name) when is_binary(tool_name) do
    case parse(policy) do
      {:ok, policy} ->
        cond do
          tool_name in policy.blocked_tools ->
            "Tool '#{tool_name}' is in blocked_tools list"

          tool_name in policy.deny ->
            "Tool '#{tool_name}' is in deny list"

          policy.allow != :all and tool_name not in policy.allow ->
            "Tool '#{tool_name}' not in allowed list"

          true ->
            nil
        end

      {:error, _reason} ->
        "Tool policy is invalid"
    end
  end

  def denial_reason(_policy, _tool_name), do: "Tool policy is invalid"

  @doc "Filters a tool list through a validated policy."
  def apply_policy(policy, tools), do: Enum.filter(tools, &allowed?(policy, &1.name))

  @doc "Partitions a tool list into allowed and denied entries."
  def partition_tools(policy, tools), do: Enum.split_with(tools, &allowed?(policy, &1.name))

  @doc "Filters a tool map through a validated policy."
  def apply_policy_to_map(policy, tools_map) do
    Map.filter(tools_map, fn {name, _tool} -> allowed?(policy, name) end)
  end

  @doc "Returns a bounded string-keyed representation for persistence or transport."
  @spec to_map(t() | map()) :: map()
  def to_map(policy) do
    policy = parse!(policy)

    %{
      "allow" => encode_allow(policy.allow),
      "deny" => policy.deny,
      "blocked_tools" => policy.blocked_tools,
      "require_approval" => policy.require_approval,
      "approvals" =>
        Map.new(policy.approvals, fn {tool, mode} -> {tool, Atom.to_string(mode)} end),
      "no_reply" => policy.no_reply,
      "profile" => if(policy.profile, do: Atom.to_string(policy.profile)),
      "allowed_commands" => encode_allow(policy.allowed_commands),
      "blocked_commands" => policy.blocked_commands,
      "max_file_size" => policy.max_file_size,
      "sandbox" => policy.sandbox
    }
  end

  @doc "Compatibility parser that raises instead of broadening malformed input."
  @spec from_map(map()) :: t()
  def from_map(map), do: parse!(map)

  @doc "Returns the most restrictive policy."
  @spec deny_all() :: t()
  def deny_all do
    %__MODULE__{
      allow: [],
      deny: [],
      blocked_tools: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: nil,
      allowed_commands: [],
      blocked_commands: [],
      max_file_size: nil,
      sandbox: true
    }
  end

  @doc "Marks a message as NO_REPLY."
  def mark_no_reply(message, opts \\ []) do
    message
    |> Map.put(:no_reply, true)
    |> Map.put(:no_reply_reason, Keyword.get(opts, :reason, "silent"))
  end

  @doc "Checks a message's NO_REPLY flag."
  def message_no_reply?(message) do
    Map.get(message, :no_reply, false) or Map.get(message, "no_reply", false)
  end

  @doc "Separates normal messages from NO_REPLY messages."
  def filter_no_reply(messages), do: Enum.split_with(messages, &(not message_no_reply?(&1)))

  defp parse_map(map) do
    with :ok <- validate_known_keys(map),
         {:ok, fields} <- extract_fields(map),
         {:ok, base} <- parse_base_profile(fields),
         {:ok, allow} <- parse_allow(Map.get(fields, :allow, base.allow), :allow),
         {:ok, deny} <- parse_string_list(Map.get(fields, :deny, base.deny), :deny),
         {:ok, blocked_tools} <-
           parse_string_list(Map.get(fields, :blocked_tools, base.blocked_tools), :blocked_tools),
         {:ok, require_approval} <-
           parse_string_list(
             Map.get(fields, :require_approval, base.require_approval),
             :require_approval
           ),
         {:ok, approvals} <-
           parse_approvals(Map.get(fields, :approvals, base.approvals)),
         {:ok, no_reply} <- parse_boolean(Map.get(fields, :no_reply, base.no_reply), :no_reply),
         {:ok, allowed_commands} <-
           parse_allow(
             Map.get(fields, :allowed_commands, base.allowed_commands),
             :allowed_commands
           ),
         {:ok, blocked_commands} <-
           parse_string_list(
             Map.get(fields, :blocked_commands, base.blocked_commands),
             :blocked_commands
           ),
         {:ok, max_file_size} <-
           parse_optional_positive_integer(
             Map.get(fields, :max_file_size, base.max_file_size),
             :max_file_size
           ),
         {:ok, sandbox} <- parse_boolean(Map.get(fields, :sandbox, base.sandbox), :sandbox) do
      {:ok,
       %__MODULE__{
         allow: allow,
         deny: deny,
         blocked_tools: blocked_tools,
         require_approval: require_approval,
         approvals: approvals,
         no_reply: no_reply,
         profile: base.profile,
         allowed_commands: allowed_commands,
         blocked_commands: blocked_commands,
         max_file_size: max_file_size,
         sandbox: sandbox
       }}
    end
  end

  defp parse_base_profile(fields) do
    case Map.fetch(fields, :profile) do
      :error -> {:ok, profile_policy(:custom)}
      {:ok, nil} -> {:ok, %{profile_policy(:custom) | profile: nil}}
      {:ok, profile} -> fetch_profile(profile)
    end
  end

  defp validate_known_keys(map) do
    allowed = Enum.flat_map(@policy_keys, &[&1, Atom.to_string(&1)])

    case Enum.reject(Map.keys(map), &(&1 in allowed or &1 == :__struct__)) do
      [] -> :ok
      unknown -> {:error, {:unknown_policy_keys, Enum.sort_by(unknown, &to_string/1)}}
    end
  end

  defp extract_fields(map) do
    Enum.reduce_while(@policy_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      atom_value = Map.fetch(map, key)
      string_value = Map.fetch(map, Atom.to_string(key))

      case {atom_value, string_value} do
        {:error, :error} ->
          {:cont, {:ok, acc}}

        {{:ok, value}, :error} ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {:error, {:ok, value}} ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {{:ok, value}, {:ok, value}} ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {{:ok, _atom_value}, {:ok, _string_value}} ->
          {:halt, {:error, {:conflicting_policy_key, key}}}
      end
    end)
  end

  defp parse_allow(:all, _field), do: {:ok, :all}
  defp parse_allow("all", _field), do: {:ok, :all}
  defp parse_allow(value, field), do: parse_string_list(value, field)

  defp parse_string_list(value, field) when is_binary(value) or is_atom(value) do
    parse_string_list([value], field)
  end

  defp parse_string_list(value, field) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_name(item) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, {:invalid_policy_field, field}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp parse_string_list(_value, field), do: {:error, {:invalid_policy_field, field}}

  defp normalize_name(value) when is_atom(value), do: normalize_name(Atom.to_string(value))

  defp normalize_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      normalized when byte_size(normalized) <= 256 -> {:ok, normalized}
      _too_long -> :error
    end
  end

  defp normalize_name(_value), do: :error

  defp parse_approvals(approvals) when is_map(approvals) do
    Enum.reduce_while(approvals, {:ok, %{}}, fn {tool, mode}, {:ok, acc} ->
      with {:ok, tool} <- normalize_name(tool),
           {:ok, mode} <- parse_approval_mode(mode) do
        {:cont, {:ok, Map.put(acc, tool, mode)}}
      else
        _ -> {:halt, {:error, {:invalid_policy_field, :approvals}}}
      end
    end)
  end

  defp parse_approvals(_approvals), do: {:error, {:invalid_policy_field, :approvals}}

  defp parse_approval_mode(%{"mode" => mode}), do: parse_approval_mode(mode)
  defp parse_approval_mode(%{mode: mode}), do: parse_approval_mode(mode)

  defp parse_approval_mode(mode) when mode in [:always, "always", true, :required, "required"],
    do: {:ok, :always}

  defp parse_approval_mode(mode) when mode in [:dangerous, "dangerous"],
    do: {:ok, :dangerous}

  defp parse_approval_mode(mode) when mode in [:never, "never", false, :none, "none"],
    do: {:ok, :never}

  defp parse_approval_mode(_mode), do: :error

  defp parse_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp parse_boolean(_value, field), do: {:error, {:invalid_policy_field, field}}

  defp parse_optional_positive_integer(nil, _field), do: {:ok, nil}

  defp parse_optional_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_optional_positive_integer(_value, field),
    do: {:error, {:invalid_policy_field, field}}

  defp profile_policy(:full_access), do: base_policy(:full_access)
  defp profile_policy(:orchestrator), do: base_policy(:orchestrator)

  defp profile_policy(:leaf_worker) do
    %{base_policy(:leaf_worker) | deny: ["task", "agent"]}
  end

  defp profile_policy(:minimal_core) do
    %{base_policy(:minimal_core) | allow: @minimal_core_tools}
  end

  defp profile_policy(:read_only), do: %{base_policy(:read_only) | allow: @read_tools}
  defp profile_policy(:safe_mode), do: %{base_policy(:safe_mode) | deny: @dangerous_tools}

  defp profile_policy(:subagent_restricted) do
    %{
      base_policy(:subagent_restricted)
      | deny: @dangerous_tools,
        require_approval: ["write", "edit"]
    }
  end

  defp profile_policy(:no_external), do: %{base_policy(:no_external) | deny: @external_tools}
  defp profile_policy(:custom), do: base_policy(:custom)

  defp base_policy(profile) do
    %__MODULE__{
      allow: :all,
      deny: [],
      blocked_tools: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: profile,
      allowed_commands: :all,
      blocked_commands: [],
      max_file_size: nil,
      sandbox: false
    }
  end

  defp intersect_allow(:all, right), do: right
  defp intersect_allow(left, :all), do: left
  defp intersect_allow(left, right), do: Enum.filter(left, &(&1 in right))

  defp union(left, right), do: Enum.uniq(left ++ right)

  defp merge_approvals(parent, requested) do
    Map.merge(parent, requested, fn _tool, left, right ->
      if approval_rank(left) >= approval_rank(right), do: left, else: right
    end)
  end

  defp approval_rank(:always), do: 3
  defp approval_rank(:dangerous), do: 2
  defp approval_rank(:never), do: 1

  defp minimum_limit(nil, right), do: right
  defp minimum_limit(left, nil), do: left
  defp minimum_limit(left, right), do: min(left, right)

  defp encode_allow(:all), do: "all"
  defp encode_allow(values), do: values
end
