defmodule LemonCore.Config.ProjectLayer do
  @moduledoc """
  Trust boundary between the operator's global config and a project
  `.lemon/config.toml`.

  A project file arrives with the repository, so anyone who can commit to a
  repository the operator opens can write it. It may therefore set only the
  preferences and policy narrowings in this module's allowlist; every other key
  is operator authority. That covers credential destinations and selectors
  (`providers.*`, web tool hosts and secrets, gateway sections), secret sources,
  executable and extension paths, LSP/WASM/shell settings, SSRF switches,
  logging destinations, credential pools and any policy widening. An ignored
  key is reported, never silently honoured.

  Allowed preferences (project value wins):

    * `defaults.provider`, `defaults.model`, `defaults.thinking_level`
    * `model_roles.*`
    * `tui.*` (`prompt_history` may only be turned off)
    * `runtime.compaction.*`, `runtime.task.agent_models.*`
    * `runtime.tools.auto_resize_images`, `runtime.tools.edit.enforce_seen_lines`,
      `runtime.tools.bash.interceptor.*`
    * `runtime.tools.disclosure.*` (`profile` limited to `auto`, `coding`,
      `legacy`)
    * `profiles.<operator id>.name`, `description`, `avatar` for a profile the
      operator already defines (`default` always exists); a profile's `model`
      is operator-only, since delegated runs use it without the task gate

  Narrow-only policy (the result is never wider than the operator value):

    * `runtime.tools.approval_mode`: only a stricter mode (`yolo` < unset <
      `write` < `ask`)
    * `runtime.task.per_call_model` lowers, `per_call_model_allow` intersects
    * `runtime.task.disabled_agents`: union with the operator list
    * `runtime.max_tool_turns`, `budgets.*`, `model_routing.max_cost_usd`: a
      cap no higher than the operator's (any cap when the operator has none).
      Every other `model_routing` key (`enabled`, `rules`) is operator-only:
      routing picks the request model after task selection is gated.
    * `runtime.tools.bash.git_guard`, `runtime.secret_obfuscation.enabled`,
      `memory.write_approval`, `skills.write_approval`: only `true`
    * `memory.auto_recall`: only `false`
    * `features.*`: only `"off"`
    * `runtime.tools.lsp.servers.<id>.disabled`: only `true`
    * `profiles.<operator id>.tool_policy`: intersected with the effective
      operator policy (including the inherited global `approval_mode`); a
      weaker mode, a per-tool approval other than `always`, or
      `workspace_read_exempt = true` the operator does not already grant
      rejects the project policy

  Both layers must already be mapped from a legacy `[agent]` table.
  """

  alias LemonCore.MapHelpers
  alias LemonCore.ToolPolicy

  @typedoc "Why a project key was ignored."
  @type reason :: :operator_only | :narrow_only

  @typedoc "Dotted key path of an ignored project value and why it was ignored."
  @type rejection :: {String.t(), reason()}

  @per_call_mode_rank %{"off" => 0, "on" => 1}
  # Unset sits between `yolo` (skips even WASM capability approvals) and `write`.
  @approval_rank %{"yolo" => 0, nil => 1, "write" => 2, "ask" => 3}
  @disclosure_profiles ~w(auto coding legacy)
  @profile_preferences ~w(name description avatar)

  @rules %{
    "defaults" => %{"provider" => :allow, "model" => :allow, "thinking_level" => :allow},
    "model_roles" => :allow,
    # Routing rules and enablement choose the request model, so they are
    # operator authority; a project may only lower the routing cost cap.
    "model_routing" => %{"max_cost_usd" => {:narrow, :lower_cap}},
    "tui" => %{"prompt_history" => {:narrow, :false_only}, :any => :allow},
    "budgets" => %{:any => {:narrow, :lower_cap}},
    "features" => %{:any => {:narrow, :off_only}},
    "memory" => %{
      "write_approval" => {:narrow, :true_only},
      "auto_recall" => {:narrow, :false_only}
    },
    "skills" => %{"write_approval" => {:narrow, :true_only}},
    "profiles" => :profiles,
    "runtime" => %{
      "max_tool_turns" => {:narrow, :lower_turns},
      "compaction" => :allow,
      "secret_obfuscation" => %{"enabled" => {:narrow, :true_only}},
      "task" => %{
        "agent_models" => :allow,
        "disabled_agents" => {:narrow, :union},
        "per_call_model" => {:narrow, :per_call_mode},
        "per_call_model_allow" => {:narrow, :per_call_allow}
      },
      "tools" => %{
        "approval_mode" => {:narrow, :approval_mode},
        "auto_resize_images" => :allow,
        "edit" => %{"enforce_seen_lines" => :allow},
        "bash" => %{"git_guard" => {:narrow, :true_only}, "interceptor" => :allow},
        "disclosure" => %{"profile" => {:narrow, :disclosure_profile}, :any => :allow},
        "lsp" => %{"servers" => %{:any => %{"disabled" => {:narrow, :true_only}}}}
      }
    }
  }

  @doc """
  Merges `project` over `operator`, keeping only allowlisted project keys.

  Returns the merged settings and one rejection per ignored project leaf
  (a non-table value), in key order.
  """
  @spec merge(map(), map()) :: {map(), [rejection()]}
  def merge(operator, project) when is_map(operator) and is_map(project) do
    rules = Map.put(@rules, "profiles", {:profiles, operator_approval_mode(operator)})
    {allowed, puts, rejected} = walk(project, rules, operator, [])

    merged =
      Enum.reduce(puts, MapHelpers.deep_merge(operator, allowed), fn
        {:put, path, value}, acc -> put_path(acc, path, value)
        {:delete, path}, acc -> delete_path(acc, path)
      end)

    {merged, Enum.reverse(rejected)}
  end

  @doc "Human-readable message for a rejection, prefixed with the project file."
  @spec format(String.t(), rejection()) :: String.t()
  def format(path, {key, :operator_only}) do
    "#{path}: #{key}: operator-only setting ignored in project config; " <>
      "set it in the global config (#{LemonCore.Paths.global_config()})"
  end

  def format(path, {key, :narrow_only}) do
    "#{path}: #{key}: project config may only narrow this setting; value ignored"
  end

  # ── walk ───────────────────────────────────────────────────────────────────

  defp walk(project, rules, operator, prefix) do
    project
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, [], []}, fn {key, value}, {allowed, puts, rejected} ->
      path = prefix ++ [key]
      operator_value = if is_map(operator), do: Map.get(operator, key)

      case apply_rule(rule_for(rules, key), value, operator_value, path) do
        {:allow, value} ->
          {Map.put(allowed, key, value), puts, rejected}

        {:nested, nested, nested_puts, nested_rejected} ->
          allowed = if nested == %{}, do: allowed, else: Map.put(allowed, key, nested)
          {allowed, nested_puts ++ puts, nested_rejected ++ rejected}

        {:puts, new_puts} ->
          {allowed, new_puts ++ puts, rejected}

        {:reject, reason} ->
          {allowed, puts, leaves(value, path, reason) ++ rejected}
      end
    end)
  end

  defp rule_for(rules, key) when is_map(rules), do: Map.get(rules, key, Map.get(rules, :any))
  defp rule_for(_rules, _key), do: nil

  defp apply_rule(nil, _value, _operator, _path), do: {:reject, :operator_only}
  defp apply_rule(:allow, value, _operator, _path), do: {:allow, value}

  defp apply_rule({:profiles, global_mode}, value, operator, path) when is_map(value) do
    operator = if is_map(operator), do: operator, else: %{}
    rules = Map.new(Map.keys(operator) ++ ["default"], &{&1, {:profile, global_mode}})
    {allowed, puts, rejected} = walk(value, rules, operator, path)
    {:nested, allowed, puts, rejected}
  end

  defp apply_rule({:profile, global_mode}, value, operator, path) when is_map(value) do
    rules = Map.new(@profile_preferences, &{&1, :allow})
    {policy, preferences} = Map.pop(value, "tool_policy")
    {allowed, puts, rejected} = walk(preferences, rules, operator, path)

    case policy do
      nil ->
        {:nested, allowed, puts, rejected}

      policy ->
        case narrow_tool_policy(operator, policy, global_mode) do
          # A JSON policy would win over the table in `LemonCore.Config`; drop
          # it so the intersected table is the profile's only policy.
          {:ok, narrowed} ->
            policy_puts = [
              {:delete, path ++ ["tool_policy_json"]},
              {:put, path ++ ["tool_policy"], narrowed}
            ]

            {:nested, allowed, policy_puts ++ puts, rejected}

          :error ->
            policy_rejected = leaves(policy, path ++ ["tool_policy"], :narrow_only)
            {:nested, allowed, puts, policy_rejected ++ rejected}
        end
    end
  end

  defp apply_rule(rules, value, operator, path) when is_map(rules) and is_map(value) do
    {allowed, puts, rejected} = walk(value, rules, operator, path)
    {:nested, allowed, puts, rejected}
  end

  defp apply_rule({:narrow, kind}, value, operator, path) do
    case narrow(kind, operator, value) do
      {:ok, narrowed} -> {:puts, [{:put, path, narrowed}]}
      :error -> {:reject, :narrow_only}
    end
  end

  defp apply_rule(_rule, _value, _operator, _path), do: {:reject, :operator_only}

  # Every leaf under a rejected table is reported so each ignored line is named.
  defp leaves(value, path, reason) when is_map(value) and map_size(value) > 0 do
    value
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.flat_map(fn {key, nested} -> leaves(nested, path ++ [key], reason) end)
  end

  defp leaves(_value, path, reason), do: [{Enum.join(path, "."), reason}]

  # ── narrowing ──────────────────────────────────────────────────────────────

  defp narrow(:true_only, _operator, true), do: {:ok, true}
  defp narrow(:false_only, _operator, false), do: {:ok, false}
  defp narrow(:off_only, _operator, "off"), do: {:ok, "off"}

  defp narrow(:disclosure_profile, _operator, profile) when profile in @disclosure_profiles,
    do: {:ok, profile}

  # Budgets and `max_cost_usd`: zero is a real (blocking) cap; unset is unlimited.
  defp narrow(:lower_cap, operator, value) when is_number(value) and value >= 0 do
    if is_number(operator) and operator >= 0 and value > operator,
      do: :error,
      else: {:ok, value}
  end

  # `max_tool_turns`: zero or unset is unlimited.
  defp narrow(:lower_turns, operator, value) when is_integer(value) and value > 0 do
    if is_integer(operator) and operator > 0 and value > operator,
      do: :error,
      else: {:ok, value}
  end

  defp narrow(:union, operator, value) when is_list(value) do
    operator = if is_list(operator), do: operator, else: []
    {:ok, Enum.uniq(operator ++ value)}
  end

  defp narrow(:approval_mode, operator, value) do
    with project when is_integer(project) <- Map.get(@approval_rank, value),
         current when is_integer(current) <- Map.get(@approval_rank, operator, 1),
         true <- project >= current do
      {:ok, value}
    else
      _ -> :error
    end
  end

  # An unset operator mode is `off`. Unknown project values pass through so the
  # validator reports them rather than silently widening.
  defp narrow(:per_call_mode, operator, value) do
    operator = operator || "off"

    case {@per_call_mode_rank[operator], @per_call_mode_rank[value]} do
      {nil, _} -> {:ok, operator}
      {_, nil} -> {:ok, value}
      {current, project} when project < current -> {:ok, value}
      _ -> {:ok, operator}
    end
  end

  defp narrow(:per_call_allow, operator, value), do: {:ok, narrow_allowlist(operator, value)}
  defp narrow(_kind, _operator, _value), do: :error

  defp narrow_allowlist(nil, project), do: project

  defp narrow_allowlist(allow, project) when is_list(allow) and is_list(project) do
    trimmed = MapSet.new(project, &trim_selector/1)
    Enum.filter(allow, &MapSet.member?(trimmed, trim_selector(&1)))
  end

  defp narrow_allowlist(allow, project), do: if(is_list(allow), do: project, else: allow)

  defp trim_selector(value) when is_binary(value), do: String.trim(value)
  defp trim_selector(value), do: value

  # The project policy is intersected with the operator's EFFECTIVE policy: the
  # profile policy (or the profile default) with the global
  # `runtime.tools.approval_mode` inherited when the profile sets none, exactly
  # as a session applies it. Checks run on the parsed project policy, so a
  # preset `profile` cannot smuggle a value in. A project may not:
  #   * lower that approval mode;
  #   * relax a per-tool approval (only `always` entries are accepted);
  #   * set `workspace_read_exempt = true` unless the operator policy already
  #     does (the intersection treats unset as neutral, so true would widen).
  # `no_reply`, the other boolean field, only restricts (intersection ORs it).
  # Any violation rejects the whole project policy.
  defp narrow_tool_policy(operator_profile, project, global_mode) do
    with {:ok, project} <- policy_input(project),
         {:ok, parsed} <- ToolPolicy.parse(project),
         operator = effective_operator_policy(operator_profile, global_mode),
         true <- approval_mode_allowed?(parsed.approval_mode, operator),
         true <- only_always_approvals?(parsed.approvals),
         true <- parsed.workspace_read_exempt != true or operator.workspace_read_exempt == true do
      {:ok, ToolPolicy.intersect(operator, project)}
    else
      _ -> :error
    end
  end

  defp operator_approval_mode(operator) do
    with %{} = runtime <- operator["runtime"],
         %{} = tools <- runtime["tools"] do
      tools["approval_mode"]
    else
      _ -> nil
    end
  end

  defp effective_operator_policy(profile, global_mode) do
    policy =
      case ToolPolicy.parse(operator_policy(profile)) do
        {:ok, policy} -> policy
        {:error, _reason} -> ToolPolicy.deny_all()
      end

    ToolPolicy.with_default_approval_mode(policy, global_mode)
  rescue
    # An invalid global mode is reported by the validator; fail closed here.
    ArgumentError -> ToolPolicy.deny_all()
  end

  defp approval_mode_allowed?(nil, _operator), do: true

  defp approval_mode_allowed?(mode, operator) do
    project = Map.get(@approval_rank, mode_key(mode))

    is_integer(project) and
      project >= Map.get(@approval_rank, mode_key(operator.approval_mode), 1)
  end

  defp mode_key(mode) when is_atom(mode) and not is_nil(mode), do: Atom.to_string(mode)
  defp mode_key(mode), do: mode

  # A parsed policy's approvals map holds atom modes.
  defp only_always_approvals?(approvals),
    do: Enum.all?(approvals, fn {_tool, mode} -> mode == :always end)

  # Mirrors `LemonCore.Config`: a JSON policy wins over the table, an invalid
  # operator policy denies everything, and an absent one is the profile default.
  defp operator_policy(%{"tool_policy_json" => json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, policy} when not is_nil(policy) -> operator_policy(%{"tool_policy" => policy})
      _ -> ToolPolicy.deny_all()
    end
  end

  defp operator_policy(%{"tool_policy_json" => _invalid}), do: ToolPolicy.deny_all()

  defp operator_policy(%{"tool_policy" => policy}) when not is_nil(policy) do
    case policy_input(policy) do
      {:ok, policy} -> policy
      :error -> ToolPolicy.deny_all()
    end
  end

  defp operator_policy(_profile), do: %{}

  defp policy_input(profile) when is_binary(profile) do
    case ToolPolicy.fetch_profile(profile) do
      {:ok, policy} -> {:ok, policy}
      {:error, _reason} -> :error
    end
  end

  defp policy_input(policy) when is_map(policy), do: {:ok, policy}
  defp policy_input(_policy), do: :error

  # ── path helpers ───────────────────────────────────────────────────────────

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    child = Map.get(map, key)
    Map.put(map, key, put_path(if(is_map(child), do: child, else: %{}), rest, value))
  end

  defp delete_path(map, [key]), do: Map.delete(map, key)

  defp delete_path(map, [key | rest]) do
    case Map.get(map, key) do
      child when is_map(child) -> Map.put(map, key, delete_path(child, rest))
      _ -> map
    end
  end
end
