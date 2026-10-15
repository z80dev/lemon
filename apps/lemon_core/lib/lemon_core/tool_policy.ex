defmodule LemonCore.ToolPolicy do
  @moduledoc """
  Canonical, validated authorization policy for Lemon tool execution.

  Use `parse/1` for untrusted atom- or string-keyed input; malformed input is
  rejected instead of being normalized to full access. Validated structs carry
  execution authority; `normalize/1` preserves sparse JSON policy projections
  used by durable admission and `to_map/1` encodes a complete policy.

  `restrict/2` computes the intersection of two policies. It is used for
  delegated work so a child request cannot remove a parent denial or approval
  requirement.
  """

  @type approval_mode :: :always | :dangerous | :never
  @type tier :: :read | :write | :exec
  @type global_approval_mode :: :ask | :write | :yolo | nil
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
          approval_mode: global_approval_mode(),
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
    :approval_mode,
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
    :approval_mode,
    :no_reply,
    :profile,
    :allowed_commands,
    :blocked_commands,
    :max_file_size,
    :sandbox
  ]

  @native_keys [
    :allow,
    :deny,
    :blocked_tools,
    :require_approval,
    :approvals,
    :approval_mode,
    :no_reply,
    :profile
  ]
  @max_tool_entries 16_384
  @execution_json_items 131_072
  @execution_json_bytes 16_777_216

  @read_tools ["read", "read_skill", "recall", "grep", "find", "ls", "checkpoint", "rewind"]

  @minimal_core_tools [
    "read",
    "read_skill",
    "skill_manage",
    "remember",
    "recall",
    "fs_checkpoint",
    "checkpoint",
    "rewind",
    "write",
    "edit",
    "patch",
    "ast_grep",
    "bash",
    "bash_output",
    "kill_process",
    "process_input",
    "eval",
    "grep",
    "find",
    "ls",
    "webfetch",
    "websearch",
    "browser_tabs",
    "browser_tab_open",
    "browser_tab_activate",
    "browser_tab_close",
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
    "media_status",
    "media_generate_image",
    "media_generate_speech",
    "media_transcribe_audio",
    "media_analyze_image",
    "media_generate_video",
    "todo",
    "kanban",
    "goal",
    "cron",
    "task",
    "agent",
    "extensions_status"
  ]

  @external_tools [
    "webfetch",
    "websearch",
    "browser_tabs",
    "browser_tab_open",
    "browser_tab_activate",
    "browser_tab_close",
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
    "patch",
    "ast_grep",
    "fs_checkpoint",
    "skill_manage",
    "remember",
    "bash",
    # Persistent kernels and debuggers execute arbitrary project code.
    "eval",
    "debug",
    # Language servers can execute project code and apply file edits.
    "lsp",
    # Runs project compilers/checkers (`mix compile`, `cargo check`, `go test`),
    # which execute project code.
    "lsp_diagnostics",
    "kill_process",
    "process_input",
    "agent",
    "task",
    "goal",
    "kanban",
    "cron",
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
    "media_generate_image",
    "media_generate_speech",
    "media_transcribe_audio",
    "media_analyze_image",
    "media_generate_video"
  ]

  @write_tools ~w(write edit patch ast_grep fs_checkpoint skill_manage remember todo todowrite kanban goal cron)
  @approval_read_tools @read_tools ++
                         ~w(ast_search bash_output webfetch websearch wait ask ask_parent extensions_status media_status tool_search)
  @browser_read_tools ~w(browser_tabs browser_snapshot browser_get_content browser_wait_for_selector browser_events browser_get_cookies)
  @browser_write_tools ~w(browser_tab_open browser_tab_activate browser_tab_close browser_navigate browser_click browser_type browser_hover browser_select_option browser_upload_file browser_download browser_press browser_scroll browser_back browser_set_cookies browser_clear_state browser_screenshot)
  @lsp_read_actions ~w(diagnostics definition type_definition implementation references hover symbols rename rename_file code_actions capabilities status)

  @doc "Classifies built-ins; unclassified, external and executable surfaces fail closed to exec."
  @spec tier(String.t(), map()) :: tier()
  def tier(tool, args \\ %{})

  def tier("lsp", args) when is_map(args) do
    action = Map.get(args, "action", Map.get(args, :action))
    apply? = Map.get(args, "apply", Map.get(args, :apply, false))
    if action in @lsp_read_actions and apply? in [false, nil], do: :read, else: :exec
  end

  def tier(tool, _args) when tool in @write_tools or tool in @browser_write_tools, do: :write

  def tier(tool, _args) when tool in @approval_read_tools or tool in @browser_read_tools,
    do: :read

  def tier(_tool, _args), do: :exec

  @doc "Seeds only an unset mode from config. Explicit PolicyStore/session policy wins."
  def with_default_approval_mode(policy, mode) do
    policy = parse!(policy)

    if is_nil(policy.approval_mode),
      do: parse!(%{policy | approval_mode: mode}),
      else: policy
  end

  @doc """
  JSON boundary defaults for rich native execution policy/connector payloads.
  Explicit lower transport limits remain authoritative; unrelated JSON payloads
  retain `LemonCore.JSONPayload` defaults.
  """
  def execution_json_opts(opts \\ []) do
    opts
    |> Keyword.put_new(:max_items, @execution_json_items)
    |> Keyword.put_new(:max_bytes, @execution_json_bytes)
  end

  @doc false
  def execution_max_bytes, do: @execution_json_bytes

  @doc false
  def execution_max_items, do: @execution_json_items

  @doc """
  Validate a native policy and preserve its bounded, sparse JSON projection.

  Durable native policies require explicit `always` or `never` approval gates;
  conditional `dangerous` approval modes remain an execution-policy concern.
  """
  def normalize(policy) when is_map(policy) do
    with {:ok, validated} <- parse(policy),
         true <- Enum.all?(validated.approvals, fn {_tool, mode} -> mode in [:always, :never] end) do
      keys = policy |> supplied_keys() |> Enum.map(&Atom.to_string/1)
      {:ok, validated |> encode_policy() |> Map.take(keys)}
    else
      _ -> {:error, {:invalid_field, :tool_policy}}
    end
  end

  def normalize(_policy), do: {:error, {:invalid_field, :tool_policy}}

  @doc "Expand preset floors while retaining the native map projection."
  def expand(nil), do: %{}

  def expand(policy) when is_map(policy) do
    case parse(policy) do
      {:ok, validated} ->
        keys = supplied_keys(policy)

        keys =
          if :profile in keys and validated.profile, do: union(@native_keys, keys), else: keys

        validated |> Map.from_struct() |> Map.take(keys)

      {:error, _reason} ->
        Map.from_struct(deny_all())
    end
  end

  def expand(_policy), do: Map.from_struct(deny_all())

  @doc "Intersect native policy maps without widening floors or treating malformed input as absent."
  def intersect(left, right) do
    left = expand(left)
    right = expand(right)

    case restrict(left, right) do
      {:ok, policy} ->
        policy = %{
          policy
          | profile: Map.get(right, :profile, Map.get(left, :profile, policy.profile))
        }

        keys = union(Map.keys(left), Map.keys(right))
        policy |> Map.from_struct() |> Map.take(keys)

      {:error, _reason} ->
        Map.from_struct(deny_all())
    end
  end

  @doc "Normalize known top-level keys without creating atoms from input."
  def atomize(policy) when is_map(policy) do
    Map.new(policy, fn {key, value} ->
      {Enum.find(@policy_keys, &(Atom.to_string(&1) == key)) || key, value}
    end)
  end

  defp supplied_keys(%__MODULE__{}), do: @policy_keys

  defp supplied_keys(policy) do
    Enum.filter(
      @policy_keys,
      &(Map.has_key?(policy, &1) or Map.has_key?(policy, Atom.to_string(&1)))
    )
  end

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
  def custom(opts \\ []) do
    if Keyword.keyword?(opts) do
      opts
      |> Map.new()
      |> Map.put_new(:profile, :custom)
      |> parse!()
    else
      raise ArgumentError, "tool policy options must be a keyword list"
    end
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
    fields = Map.from_struct(policy)

    if Enum.all?(@policy_keys, &Map.has_key?(fields, &1)),
      do: parse_map(fields),
      else: {:error, :invalid_tool_policy}
  end

  def parse(profile) when is_atom(profile) or is_binary(profile), do: fetch_profile(profile)
  def parse(policy) when is_struct(policy), do: {:error, :invalid_tool_policy}
  def parse(policy) when is_map(policy), do: parse_map(policy)
  def parse(_policy), do: {:error, :invalid_tool_policy}

  @doc "Revalidates a policy without trusting its struct tag or defaults."
  @spec validate(term()) :: {:ok, t()} | {:error, term()}
  def validate(policy), do: parse(policy)

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
  def resolve(nil, %__MODULE__{} = default), do: validate(default)

  def resolve(policy, %__MODULE__{} = default) do
    with {:ok, _default} <- validate(default), do: parse(policy)
  end

  def resolve(_policy, _default), do: {:error, :invalid_tool_policy}

  @doc "Intersect parent and requested authority without broadening either."
  @spec restrict(t() | map(), t() | map()) :: {:ok, t()} | {:error, term()}
  def restrict(parent, requested) do
    with {:ok, parent} <- parse(parent),
         {:ok, requested} <- parse(requested) do
      bounded_policy(%__MODULE__{
        allow: intersect_allow(parent.allow, requested.allow),
        deny: union(parent.deny, requested.deny),
        blocked_tools: union(parent.blocked_tools, requested.blocked_tools),
        require_approval: union(parent.require_approval, requested.require_approval),
        approvals: intersect_approvals(parent, requested),
        approval_mode: stricter_mode(parent.approval_mode, requested.approval_mode),
        no_reply: parent.no_reply or requested.no_reply,
        profile: :custom,
        allowed_commands: intersect_allow(parent.allowed_commands, requested.allowed_commands),
        blocked_commands: union(parent.blocked_commands, requested.blocked_commands),
        max_file_size: minimum_limit(parent.max_file_size, requested.max_file_size),
        sandbox: parent.sandbox or requested.sandbox
      })
    end
  end

  @doc "Returns true only when every effective grant and constraint is within the parent."
  @spec subset?(term(), term()) :: boolean()
  def subset?(child, parent) do
    with {:ok, child} <- parse(child),
         {:ok, parent} <- parse(parent) do
      grants_subset?(
        child.allow,
        child.deny ++ child.blocked_tools,
        parent.allow,
        parent.deny ++ parent.blocked_tools
      ) and
        grants_subset?(
          child.allowed_commands,
          child.blocked_commands,
          parent.allowed_commands,
          parent.blocked_commands
        ) and
        global_mode_rank(child.approval_mode) >= global_mode_rank(parent.approval_mode) and
        Enum.all?(
          union(parent.require_approval, Map.keys(parent.approvals) ++ Map.keys(child.approvals)),
          fn tool ->
            not authorized?(child, tool) or
              approval_strength(child, tool) >= approval_strength(parent, tool)
          end
        ) and
        (not parent.no_reply or child.no_reply) and
        (not parent.sandbox or child.sandbox) and
        (is_nil(parent.max_file_size) or
           (is_integer(child.max_file_size) and child.max_file_size <= parent.max_file_size))
    else
      _ -> false
    end
  end

  @doc "Checks whether a tool is authorized. Invalid input fails closed."
  @spec allowed?(t() | map(), String.t()) :: boolean()
  def allowed?(policy, tool_name) when is_binary(tool_name) do
    case parse(policy) do
      {:ok, policy} ->
        authorized?(policy, tool_name)

      {:error, _reason} ->
        false
    end
  end

  def allowed?(_policy, _tool_name), do: false

  defp authorized?(policy, tool_name) do
    tool_name not in policy.blocked_tools and tool_name not in policy.deny and
      (policy.allow == :all or tool_name in policy.allow)
  end

  @doc "Checks approval against the actual arguments and optional source-resolved tier."
  def requires_approval?(policy, tool_name, args \\ %{}, resolved_tier \\ nil)

  def requires_approval?(policy, tool_name, args, resolved_tier) when is_binary(tool_name) do
    case parse(policy) do
      {:ok, policy} ->
        tool_name in policy.require_approval or
          case Map.get(policy.approvals, tool_name, :inherit) do
            mode when mode in [:always, :dangerous] ->
              true

            :never ->
              false

            :inherit ->
              tier = resolved_tier || tier(tool_name, args)

              case policy.approval_mode do
                :ask -> tier != :read
                :write -> tier == :exec
                _ -> false
              end
          end

      {:error, _reason} ->
        true
    end
  end

  def requires_approval?(_policy, _tool_name, _args, _tier), do: true

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
  def apply_policy(policy, tools) do
    case parse(policy) do
      {:ok, policy} -> Enum.filter(tools, &authorized?(policy, &1.name))
      {:error, _reason} -> []
    end
  end

  @doc "Partitions a tool list into allowed and denied entries."
  def partition_tools(policy, tools) do
    case parse(policy) do
      {:ok, policy} -> Enum.split_with(tools, &authorized?(policy, &1.name))
      {:error, _reason} -> {[], tools}
    end
  end

  @doc "Filters a tool map through a validated policy."
  def apply_policy_to_map(policy, tools_map) do
    case parse(policy) do
      {:ok, policy} -> Map.filter(tools_map, fn {name, _tool} -> authorized?(policy, name) end)
      {:error, _reason} -> %{}
    end
  end

  @doc "Returns a bounded string-keyed representation for persistence or transport."
  @spec to_map(t() | map()) :: map()
  def to_map(policy), do: policy |> parse!() |> encode_policy()

  defp encode_policy(policy) do
    %{
      "allow" => encode_allow(policy.allow),
      "deny" => policy.deny,
      "blocked_tools" => policy.blocked_tools,
      "require_approval" => policy.require_approval,
      "approvals" =>
        Map.new(policy.approvals, fn {tool, mode} -> {tool, Atom.to_string(mode)} end),
      "approval_mode" => if(policy.approval_mode, do: Atom.to_string(policy.approval_mode)),
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
      approval_mode: :ask,
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
         {:ok, mode} <- parse_global_mode(Map.get(fields, :approval_mode, base.approval_mode)),
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
      bounded_policy(%__MODULE__{
        allow: intersect_allow(base.allow, allow),
        deny: union(base.deny, deny),
        blocked_tools: union(base.blocked_tools, blocked_tools),
        require_approval: union(base.require_approval, require_approval),
        approvals: merge_approvals(base.approvals, approvals),
        approval_mode: mode,
        no_reply: no_reply,
        profile: base.profile,
        allowed_commands: intersect_allow(base.allowed_commands, allowed_commands),
        blocked_commands: union(base.blocked_commands, blocked_commands),
        max_file_size: minimum_limit(base.max_file_size, max_file_size),
        sandbox: sandbox
      })
    end
  end

  defp bounded_policy(policy) do
    list_keys = [
      :allow,
      :deny,
      :blocked_tools,
      :require_approval,
      :allowed_commands,
      :blocked_commands
    ]

    within_entry_limit? =
      Enum.all?(list_keys, fn key ->
        value = Map.fetch!(policy, key)
        value == :all or length(value) <= @max_tool_entries
      end)

    if within_entry_limit? and map_size(policy.approvals) <= @max_tool_entries,
      do: {:ok, policy},
      else: {:error, :tool_policy_too_large}
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

    case Enum.reject(Map.keys(map), &(&1 in allowed)) do
      [] -> :ok
      unknown -> {:error, {:unknown_policy_keys, unknown}}
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

  defp parse_string_list(value, field)
       when is_list(value) and length(value) <= @max_tool_entries do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_list_item(item, field) do
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

  defp normalize_list_item(value, field) when field in [:allowed_commands, :blocked_commands] do
    value =
      if is_atom(value) and value not in [nil, true, false],
        do: Atom.to_string(value),
        else: value

    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..4096 and
         String.trim(value) != "" and not Regex.match?(~r/[\x00-\x1f\x7f]/, value),
       do: {:ok, value},
       else: :error
  end

  defp normalize_list_item(value, _field), do: normalize_name(value)

  defp normalize_name(value) when is_atom(value) and value not in [nil, true, false],
    do: normalize_name(Atom.to_string(value))

  defp normalize_name(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..256 and
         not Regex.match?(~r/[\x00-\x20\x7f]/, value),
       do: {:ok, value},
       else: :error
  end

  defp normalize_name(_value), do: :error

  defp parse_approvals(approvals)
       when is_map(approvals) and not is_struct(approvals) and
              map_size(approvals) <= @max_tool_entries do
    Enum.reduce_while(approvals, {:ok, %{}}, fn {tool, mode}, {:ok, acc} ->
      with {:ok, tool} <- normalize_name(tool),
           {:ok, mode} <- parse_approval_mode(mode) do
        case Map.fetch(acc, tool) do
          {:ok, ^mode} -> {:cont, {:ok, acc}}
          {:ok, _other} -> {:halt, {:error, {:conflicting_policy_key, :approvals}}}
          :error -> {:cont, {:ok, Map.put(acc, tool, mode)}}
        end
      else
        _ -> {:halt, {:error, {:invalid_policy_field, :approvals}}}
      end
    end)
  end

  defp parse_approvals(_approvals), do: {:error, {:invalid_policy_field, :approvals}}

  defp parse_approval_mode(mode) when mode in [:always, "always", true, :required, "required"],
    do: {:ok, :always}

  defp parse_approval_mode(mode) when mode in [:dangerous, "dangerous"],
    do: {:ok, :dangerous}

  defp parse_approval_mode(mode) when mode in [:never, "never", false, :none, "none"],
    do: {:ok, :never}

  defp parse_approval_mode(_mode), do: :error

  defp parse_global_mode(mode) when mode in [nil, :ask, :write, :yolo], do: {:ok, mode}
  defp parse_global_mode("ask"), do: {:ok, :ask}
  defp parse_global_mode("write"), do: {:ok, :write}
  defp parse_global_mode("yolo"), do: {:ok, :yolo}
  defp parse_global_mode(_), do: {:error, {:invalid_policy_field, :approval_mode}}

  defp global_mode_rank(:ask), do: 2
  defp global_mode_rank(:write), do: 1
  defp global_mode_rank(_), do: 0

  defp stricter_mode(left, right) do
    if global_mode_rank(left) > global_mode_rank(right), do: left, else: right || left
  end

  defp intersect_approvals(parent, requested) do
    merge_approvals(parent.approvals, requested.approvals)
    |> Map.new(fn {tool, mode} ->
      required = requires_approval?(parent, tool) or requires_approval?(requested, tool)
      {tool, if(mode == :never and required, do: :always, else: mode)}
    end)
  end

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
    %{base_policy(:leaf_worker) | deny: ["task", "agent", "goal", "kanban", "cron"]}
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
      approval_mode: nil,
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
  defp intersect_allow(left, right) when left == right, do: left

  defp intersect_allow(left, right) do
    allowed = MapSet.new(right)
    Enum.filter(left, &MapSet.member?(allowed, &1))
  end

  defp union(left, right), do: Enum.uniq(left ++ right)

  defp merge_approvals(parent, requested) do
    Map.merge(parent, requested, fn _tool, left, right ->
      if approval_rank(left) >= approval_rank(right), do: left, else: right
    end)
  end

  defp approval_rank(:always), do: 3
  defp approval_rank(:dangerous), do: 2
  defp approval_rank(:never), do: 1

  defp approval_strength(policy, tool) do
    cond do
      tool in policy.require_approval -> approval_rank(:always)
      requires_approval?(policy, tool) -> approval_rank(Map.get(policy.approvals, tool, :always))
      true -> approval_rank(:never)
    end
  end

  defp grants_subset?(:all, child_denied, :all, parent_denied) do
    Enum.all?(parent_denied, &(&1 in child_denied))
  end

  defp grants_subset?(:all, _child_denied, _parent_allow, _parent_denied), do: false

  defp grants_subset?(child_allow, child_denied, parent_allow, parent_denied) do
    Enum.all?(child_allow, fn tool ->
      tool in child_denied or
        (tool not in parent_denied and (parent_allow == :all or tool in parent_allow))
    end)
  end

  defp minimum_limit(nil, right), do: right
  defp minimum_limit(left, nil), do: left
  defp minimum_limit(left, right), do: min(left, right)

  defp encode_allow(:all), do: "all"
  defp encode_allow(values), do: values
end
