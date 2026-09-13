defmodule LemonCore.ExecutionContext do
  @moduledoc """
  Immutable, validated authority resolved for one Lemon execution.

  The context binds execution identity and provenance to a validated
  `LemonCore.ToolPolicy`, workspace scope, effective capabilities, and numeric
  limits. Child contexts are created with `child/2`, which intersects requested
  authority with the parent instead of replacing it.

  Named-node transport uses `encode/1` and `decode/1`. The representation is
  versioned, JSON-safe, and validated again before destination execution.
  """

  alias LemonCore.ToolPolicy

  @version 1
  @limit_keys [:max_steps, :max_tokens, :deadline_ms, :max_file_size]
  @modes [:read_only, :read_write]

  @enforce_keys [
    :version,
    :run_id,
    :attempt_id,
    :parent_run_id,
    :principal,
    :provenance,
    :tool_policy,
    :workspace_scope,
    :capabilities,
    :limits
  ]
  defstruct @enforce_keys

  @type capability_set :: :all | [String.t()]
  @type workspace_scope :: %{root: String.t() | nil, mode: :read_only | :read_write}

  @type t :: %__MODULE__{
          version: pos_integer(),
          run_id: String.t(),
          attempt_id: String.t(),
          parent_run_id: String.t() | nil,
          principal: %{type: String.t(), id: String.t()},
          provenance: %{origin: String.t(), delegated_by: map() | nil},
          tool_policy: ToolPolicy.t(),
          workspace_scope: workspace_scope(),
          capabilities: capability_set(),
          limits: %{optional(atom()) => pos_integer()}
        }

  @doc "Current named-node representation version."
  def version, do: @version

  @doc "Builds and validates a root execution context."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, run_id} <- identifier(field(attrs, :run_id) || generated_run_id(), :run_id),
         {:ok, attempt_id} <-
           identifier(field(attrs, :attempt_id) || "#{run_id}:attempt:1", :attempt_id),
         {:ok, parent_run_id} <-
           optional_identifier(field(attrs, :parent_run_id), :parent_run_id),
         {:ok, principal} <- parse_principal(field(attrs, :principal), attrs),
         {:ok, provenance} <- parse_provenance(field(attrs, :provenance), attrs),
         {:ok, tool_policy} <-
           ToolPolicy.resolve(
             field(attrs, :tool_policy),
             ToolPolicy.from_profile(:full_access)
           ),
         {:ok, workspace_scope} <-
           parse_workspace_scope(field(attrs, :workspace_scope), field(attrs, :cwd)),
         {:ok, capabilities} <-
           parse_capabilities(field(attrs, :capabilities), tool_policy.allow),
         {:ok, limits} <- parse_limits(field(attrs, :limits)),
         {:ok, tool_policy} <- restrict_policy_to_capabilities(tool_policy, capabilities),
         :ok <- validate_workspace_policy(workspace_scope, tool_policy) do
      {:ok,
       %__MODULE__{
         version: @version,
         run_id: run_id,
         attempt_id: attempt_id,
         parent_run_id: parent_run_id,
         principal: principal,
         provenance: provenance,
         tool_policy: tool_policy,
         workspace_scope: workspace_scope,
         capabilities: capabilities,
         limits: inherit_policy_limits(limits, tool_policy)
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_execution_context}

  @doc "Validates an existing context without trusting its struct tag."
  @spec validate(term()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = context) do
    context
    |> Map.from_struct()
    |> Map.put(:cwd, get_in(context.workspace_scope, [:root]))
    |> new()
    |> preserve_version(context.version)
  end

  def validate(_context), do: {:error, :invalid_execution_context}

  @doc """
  Builds a child whose policy, capabilities, workspace, and limits are subsets
  of the parent.
  """
  @spec child(t(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def child(parent, attrs) when is_list(attrs), do: child(parent, Enum.into(attrs, %{}))

  def child(parent, attrs) when is_map(attrs) do
    with {:ok, parent} <- validate(parent),
         {:ok, requested_policy} <-
           ToolPolicy.resolve(field(attrs, :tool_policy), parent.tool_policy),
         {:ok, tool_policy} <- ToolPolicy.restrict(parent.tool_policy, requested_policy),
         {:ok, requested_capabilities} <-
           parse_capabilities(field(attrs, :capabilities), parent.capabilities),
         capabilities <- intersect_capabilities(parent.capabilities, requested_capabilities),
         {:ok, tool_policy} <- restrict_policy_to_capabilities(tool_policy, capabilities),
         {:ok, workspace_scope} <-
           child_workspace_scope(parent.workspace_scope, attrs),
         {:ok, requested_limits} <- parse_limits(field(attrs, :limits)),
         limits <- intersect_limits(parent.limits, requested_limits),
         attrs <-
           attrs
           |> Map.put(:parent_run_id, parent.run_id)
           |> Map.put(:principal, field(attrs, :principal) || parent.principal)
           |> Map.put(
             :provenance,
             field(attrs, :provenance) ||
               %{origin: "delegated", delegated_by: identity(parent)}
           )
           |> Map.put(:tool_policy, tool_policy)
           |> Map.put(:workspace_scope, workspace_scope)
           |> Map.put(:capabilities, capabilities)
           |> Map.put(:limits, limits) do
      new(attrs)
    end
  end

  def child(_parent, _attrs), do: {:error, :invalid_execution_context}

  @doc "Returns true when every child authority dimension is within the parent."
  @spec subset?(t(), t()) :: boolean()
  def subset?(child, parent) do
    with {:ok, child} <- validate(child),
         {:ok, parent} <- validate(parent),
         {:ok, intersection} <- ToolPolicy.restrict(parent.tool_policy, child.tool_policy) do
      same_authority?(intersection, child.tool_policy) and
        capability_subset?(child.capabilities, parent.capabilities) and
        workspace_subset?(child.workspace_scope, parent.workspace_scope) and
        limits_subset?(child.limits, parent.limits)
    else
      _ -> false
    end
  end

  @doc "Binds an unbound remote workspace to the destination-selected root."
  @spec bind_workspace(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def bind_workspace(context, cwd) when is_binary(cwd) do
    with {:ok, context} <- validate(context),
         {:ok, cwd} <- expanded_path(cwd),
         :ok <- ensure_path_in_scope(cwd, context.workspace_scope) do
      {:ok, %{context | workspace_scope: %{context.workspace_scope | root: cwd}}}
    end
  end

  def bind_workspace(_context, _cwd), do: {:error, :invalid_workspace_scope}

  @doc "Changes only the transport workspace binding for a named destination."
  @spec for_remote(t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def for_remote(context, _remote_cwd) do
    with {:ok, context} <- validate(context) do
      # Source and destination paths are different namespaces. The destination
      # validates the separately bounded cwd and then binds this unbound scope
      # to its canonical absolute path.
      {:ok, %{context | workspace_scope: %{context.workspace_scope | root: nil}}}
    end
  end

  @doc "Returns the versioned bounded representation used across named nodes."
  @spec encode(t()) :: {:ok, map()} | {:error, term()}
  def encode(context) do
    with {:ok, context} <- validate(context) do
      {:ok,
       %{
         "version" => context.version,
         "runId" => context.run_id,
         "attemptId" => context.attempt_id,
         "parentRunId" => context.parent_run_id,
         "principal" => stringify_simple_map(context.principal),
         "provenance" => encode_provenance(context.provenance),
         "toolPolicy" => ToolPolicy.to_map(context.tool_policy),
         "workspaceScope" => %{
           "root" => context.workspace_scope.root,
           "mode" => Atom.to_string(context.workspace_scope.mode)
         },
         "capabilities" => encode_capabilities(context.capabilities),
         "limits" => Map.new(context.limits, fn {key, value} -> {Atom.to_string(key), value} end)
       }}
    end
  end

  @doc "Decodes and revalidates a named-node execution context."
  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(map) when is_map(map) do
    with @version <- field(map, :version),
         {:ok, workspace_scope} <- decode_workspace_scope(field(map, :workspace_scope)),
         {:ok, capabilities} <- decode_capabilities(field(map, :capabilities)),
         {:ok, limits} <- decode_limits(field(map, :limits)),
         {:ok, context} <-
           new(%{
             run_id: field(map, :run_id),
             attempt_id: field(map, :attempt_id),
             parent_run_id: field(map, :parent_run_id),
             principal: field(map, :principal),
             provenance: field(map, :provenance),
             tool_policy: field(map, :tool_policy),
             workspace_scope: workspace_scope,
             capabilities: capabilities,
             limits: limits
           }) do
      {:ok, context}
    else
      version when is_integer(version) ->
        {:error, {:unsupported_execution_context_version, version}}

      nil ->
        {:error, :missing_execution_context_version}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :invalid_execution_context}
    end
  end

  def decode(_map), do: {:error, :invalid_execution_context}

  @doc "Returns the bounded lineage identity included in child provenance."
  def identity(%__MODULE__{} = context) do
    %{
      run_id: context.run_id,
      attempt_id: context.attempt_id,
      principal: context.principal
    }
  end

  @doc "Rebinds a pre-admission child context to its accepted run identity."
  @spec reidentify(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def reidentify(context, run_id) do
    with {:ok, context} <- validate(context),
         {:ok, run_id} <- identifier(run_id, :run_id) do
      {:ok,
       %{
         context
         | run_id: run_id,
           attempt_id: "#{run_id}:attempt:1"
       }}
    end
  end

  defp parse_principal(nil, attrs) do
    id = field(attrs, :agent_id) || "default"
    parse_principal(%{type: "agent", id: id}, attrs)
  end

  defp parse_principal(principal, _attrs) when is_map(principal) do
    with {:ok, type} <- identifier(field(principal, :type), :principal_type),
         {:ok, id} <- identifier(field(principal, :id), :principal_id) do
      {:ok, %{type: type, id: id}}
    end
  end

  defp parse_principal(_principal, _attrs), do: {:error, :invalid_principal}

  defp parse_provenance(nil, attrs) do
    origin = field(attrs, :origin) || "direct"
    parse_provenance(%{origin: origin}, attrs)
  end

  defp parse_provenance(provenance, _attrs) when is_atom(provenance) or is_binary(provenance) do
    parse_provenance(%{origin: provenance}, %{})
  end

  defp parse_provenance(provenance, _attrs) when is_map(provenance) do
    with {:ok, origin} <- identifier(field(provenance, :origin), :provenance_origin),
         {:ok, delegated_by} <- parse_delegated_by(field(provenance, :delegated_by)) do
      {:ok, %{origin: origin, delegated_by: delegated_by}}
    end
  end

  defp parse_provenance(_provenance, _attrs), do: {:error, :invalid_provenance}

  defp parse_delegated_by(nil), do: {:ok, nil}

  defp parse_delegated_by(value) when is_map(value) do
    safe =
      value
      |> Enum.reduce(%{}, fn {key, item}, acc ->
        key = to_string(key)

        if key in ["run_id", "runId", "attempt_id", "attemptId", "principal"] do
          Map.put(acc, key, item)
        else
          acc
        end
      end)

    {:ok, safe}
  end

  defp parse_delegated_by(_value), do: {:error, :invalid_delegated_by}

  defp parse_workspace_scope(nil, cwd) do
    with {:ok, root} <- optional_expanded_path(cwd) do
      {:ok, %{root: root, mode: :read_write}}
    end
  end

  defp parse_workspace_scope(scope, _cwd) when is_map(scope) do
    with {:ok, root} <- optional_expanded_path(field(scope, :root)),
         {:ok, mode} <- parse_mode(field(scope, :mode) || :read_write) do
      {:ok, %{root: root, mode: mode}}
    end
  end

  defp parse_workspace_scope(_scope, _cwd), do: {:error, :invalid_workspace_scope}

  defp child_workspace_scope(parent_scope, attrs) do
    requested = field(attrs, :workspace_scope)
    cwd = field(attrs, :cwd)

    with {:ok, scope} <- parse_workspace_scope(requested, cwd || parent_scope.root),
         true <- workspace_subset?(scope, parent_scope) do
      {:ok, scope}
    else
      false -> {:error, :workspace_scope_escalation}
      {:error, _reason} = error -> error
    end
  end

  defp workspace_subset?(%{root: child_root, mode: child_mode}, %{
         root: parent_root,
         mode: parent_mode
       }) do
    mode_subset?(child_mode, parent_mode) and path_subset?(child_root, parent_root)
  end

  defp mode_subset?(:read_only, _parent), do: true
  defp mode_subset?(:read_write, :read_write), do: true
  defp mode_subset?(_child, _parent), do: false

  defp path_subset?(_child, nil), do: true
  defp path_subset?(nil, _parent), do: false

  defp path_subset?(child, parent) do
    child == parent or String.starts_with?(child, parent <> Path.sep())
  end

  defp ensure_path_in_scope(_cwd, %{root: nil}), do: :ok

  defp ensure_path_in_scope(cwd, %{root: root}) do
    if path_subset?(cwd, root), do: :ok, else: {:error, :workspace_scope_mismatch}
  end

  defp validate_workspace_policy(%{mode: :read_only}, policy) do
    write_tools = ["write", "edit", "hashline_edit", "patch", "bash", "execute_code"]

    if Enum.any?(write_tools, &ToolPolicy.allowed?(policy, &1)) do
      {:error, :read_only_workspace_policy_mismatch}
    else
      :ok
    end
  end

  defp validate_workspace_policy(_scope, _policy), do: :ok

  defp parse_capabilities(nil, default), do: parse_capabilities(default, :all)
  defp parse_capabilities(:all, _default), do: {:ok, :all}
  defp parse_capabilities("all", _default), do: {:ok, :all}

  defp parse_capabilities(values, _default) when is_list(values) do
    parse_name_list(values, :capabilities)
  end

  defp parse_capabilities(_values, _default), do: {:error, :invalid_capabilities}

  defp decode_capabilities("all"), do: {:ok, :all}
  defp decode_capabilities(values), do: parse_capabilities(values, :all)
  defp encode_capabilities(:all), do: "all"
  defp encode_capabilities(values), do: values

  defp restrict_policy_to_capabilities(policy, :all), do: {:ok, policy}

  defp restrict_policy_to_capabilities(policy, capabilities) do
    ToolPolicy.restrict(policy, ToolPolicy.custom(allow: capabilities))
  end

  defp intersect_capabilities(:all, right), do: right
  defp intersect_capabilities(left, :all), do: left
  defp intersect_capabilities(left, right), do: Enum.filter(left, &(&1 in right))

  defp capability_subset?(_child, :all), do: true
  defp capability_subset?(:all, _parent), do: false
  defp capability_subset?(child, parent), do: Enum.all?(child, &(&1 in parent))

  defp parse_limits(nil), do: {:ok, %{}}

  defp parse_limits(limits) when is_map(limits) do
    Enum.reduce_while(limits, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_limit_key(key) do
        nil ->
          {:halt, {:error, {:unknown_execution_limit, key}}}

        normalized when is_integer(value) and value > 0 ->
          {:cont, {:ok, Map.put(acc, normalized, value)}}

        normalized ->
          {:halt, {:error, {:invalid_execution_limit, normalized}}}
      end
    end)
  end

  defp parse_limits(_limits), do: {:error, :invalid_execution_limits}

  defp decode_limits(limits), do: parse_limits(limits)

  defp normalize_limit_key(key) when key in @limit_keys, do: key

  defp normalize_limit_key(key) when is_binary(key) do
    Enum.find(@limit_keys, &(Atom.to_string(&1) == key))
  end

  defp normalize_limit_key(_key), do: nil

  defp inherit_policy_limits(limits, %{max_file_size: nil}), do: limits

  defp inherit_policy_limits(limits, %{max_file_size: max_file_size}) do
    Map.update(limits, :max_file_size, max_file_size, &min(&1, max_file_size))
  end

  defp intersect_limits(parent, requested) do
    Map.merge(parent, requested, fn _key, parent_value, requested_value ->
      min(parent_value, requested_value)
    end)
  end

  defp limits_subset?(child, parent) do
    Enum.all?(parent, fn {key, parent_value} ->
      case Map.fetch(child, key) do
        {:ok, child_value} -> child_value <= parent_value
        :error -> false
      end
    end)
  end

  defp same_authority?(left, right) do
    Map.take(left, [
      :allow,
      :deny,
      :blocked_tools,
      :require_approval,
      :approvals,
      :allowed_commands,
      :blocked_commands,
      :max_file_size,
      :sandbox
    ]) ==
      Map.take(right, [
        :allow,
        :deny,
        :blocked_tools,
        :require_approval,
        :approvals,
        :allowed_commands,
        :blocked_commands,
        :max_file_size,
        :sandbox
      ])
  end

  defp decode_workspace_scope(scope) when is_map(scope) do
    parse_workspace_scope(scope, field(scope, :root))
  end

  defp decode_workspace_scope(_scope), do: {:error, :invalid_workspace_scope}

  defp parse_mode(mode) when mode in @modes, do: {:ok, mode}
  defp parse_mode("read_only"), do: {:ok, :read_only}
  defp parse_mode("read_write"), do: {:ok, :read_write}
  defp parse_mode(_mode), do: {:error, :invalid_workspace_mode}

  defp parse_name_list(values, field) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case identifier(value, field) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp identifier(value, field) when is_atom(value), do: identifier(Atom.to_string(value), field)

  defp identifier(value, _field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_execution_identifier}
      value when byte_size(value) <= 512 -> {:ok, value}
      _ -> {:error, :execution_identifier_too_long}
    end
  end

  defp identifier(_value, field), do: {:error, {:invalid_execution_identifier, field}}

  defp optional_identifier(nil, _field), do: {:ok, nil}
  defp optional_identifier(value, field), do: identifier(value, field)

  defp expanded_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> {:error, :invalid_workspace_root}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp expanded_path(_path), do: {:error, :invalid_workspace_root}

  defp optional_expanded_path(nil), do: {:ok, nil}
  defp optional_expanded_path(path), do: expanded_path(path)

  defp encode_provenance(provenance) do
    %{
      "origin" => provenance.origin,
      "delegatedBy" => stringify_nested_map(provenance.delegated_by)
    }
  end

  defp stringify_simple_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_nested_map(nil), do: nil

  defp stringify_nested_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      encoded = if is_map(value), do: stringify_nested_map(value), else: value
      {camel_key(key), encoded}
    end)
  end

  defp camel_key(:run_id), do: "runId"
  defp camel_key(:attempt_id), do: "attemptId"
  defp camel_key(:parent_run_id), do: "parentRunId"
  defp camel_key(:tool_policy), do: "toolPolicy"
  defp camel_key(:workspace_scope), do: "workspaceScope"
  defp camel_key(:delegated_by), do: "delegatedBy"
  defp camel_key(key), do: to_string(key)

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) ||
      Map.get(map, Atom.to_string(key)) ||
      Map.get(map, camel_key(key))
  end

  defp field(_map, _key), do: nil

  defp generated_run_id do
    "direct:" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp preserve_version({:ok, context}, @version), do: {:ok, context}

  defp preserve_version({:ok, _context}, version),
    do: {:error, {:unsupported_execution_context_version, version}}

  defp preserve_version(error, _version), do: error
end
