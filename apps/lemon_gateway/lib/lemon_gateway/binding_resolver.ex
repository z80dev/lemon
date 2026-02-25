defmodule LemonGateway.BindingResolver do
  @moduledoc """
  Resolves bindings and settings for a given chat scope.

  Bindings map transport/chat/topic combinations to projects, engines, and queue modes.
  """

  alias LemonCore.{Binding, ChatScope, Store}
  alias LemonGateway.{Config, ConfigLoader}

  @project_overrides_table :gateway_project_overrides
  @dynamic_projects_table :gateway_projects_dynamic

  @doc """
  Resolves a binding for the given scope.

  Returns the most specific binding that matches:
  - Topic-level binding (transport + chat_id + topic_id) takes precedence
  - Falls back to chat-level binding (transport + chat_id)
  - Returns nil if no binding matches
  """
  @spec resolve_binding(ChatScope.t()) :: Binding.t() | nil
  def resolve_binding(%ChatScope{} = scope) do
    bindings = bindings()

    # First try to find a topic-level binding if topic_id is set
    topic_binding =
      if scope.topic_id do
        Enum.find(bindings, fn b ->
          get_field(b, :transport) == scope.transport &&
            get_field(b, :chat_id) == scope.chat_id &&
            get_field(b, :topic_id) == scope.topic_id
        end)
      else
        nil
      end

    # Fall back to chat-level binding
    chat_binding =
      Enum.find(bindings, fn b ->
        get_field(b, :transport) == scope.transport &&
          get_field(b, :chat_id) == scope.chat_id &&
          is_nil(get_field(b, :topic_id))
      end)

    binding = topic_binding || chat_binding
    normalize_binding(binding)
  end

  # In umbrella `mix test`, lemon_gateway may not be started even if callers
  # reference BindingResolver. Be defensive and fall back to env/TOML parsing.
  defp bindings do
    if is_pid(Process.whereis(Config)) do
      Config.get(:bindings) || []
    else
      ConfigLoader.load()
      |> Map.get(:bindings, [])
      |> List.wrap()
    end
  rescue
    _ -> []
  end

  # Helper to get field from either a struct or a map
  defp get_field(%Binding{} = b, key), do: Map.get(b, key)
  defp get_field(b, key) when is_map(b), do: b[key] || Map.get(b, key)
  defp get_field(_, _), do: nil

  # Normalize to Binding struct
  defp normalize_binding(nil), do: nil

  defp normalize_binding(%Binding{} = b) do
    %Binding{b | queue_mode: parse_queue_mode(b.queue_mode)}
  end

  defp normalize_binding(b) when is_map(b) do
    %Binding{
      transport: get_field(b, :transport),
      chat_id: get_field(b, :chat_id),
      topic_id: get_field(b, :topic_id),
      project: get_field(b, :project),
      agent_id: get_field(b, :agent_id),
      default_engine: get_field(b, :default_engine),
      queue_mode: parse_queue_mode(get_field(b, :queue_mode))
    }
  end

  # Parse queue_mode to atom, matching ConfigLoader.parse_queue_mode/1
  defp parse_queue_mode(nil), do: nil
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(mode) when is_atom(mode), do: mode

  @doc """
  Resolves the engine to use for a given scope, hint, and resume token.

  Priority order (highest to lowest):
  1. Resume token engine (from conversation continuation)
  2. Engine hint (from /engine command)
  3. Topic binding default_engine
  4. Chat binding default_engine
  5. Project default_engine
  6. Global default_engine from config
  """
  @spec resolve_engine(ChatScope.t(), String.t() | nil, map() | nil) :: String.t() | nil
  def resolve_engine(%ChatScope{} = scope, engine_hint, resume) do
    # Resume token takes highest precedence
    if resume && resume.engine do
      resume.engine
    else
      # Engine hint from command takes next precedence
      engine_hint || resolve_engine_from_binding(scope)
    end
  end

  # Be defensive: some callers/tests may pass a non-ChatScope value.
  # In that case, fall back to resume/engine_hint/default_engine without binding logic.
  def resolve_engine(_scope, engine_hint, resume) do
    cond do
      resume && resume.engine -> resume.engine
      is_binary(engine_hint) -> engine_hint
      true -> default_engine()
    end
  end

  defp resolve_engine_from_binding(scope) do
    binding = resolve_binding(scope)

    cond do
      binding && binding.default_engine ->
        binding.default_engine

      true ->
        project_id = project_id_for(scope, binding)

        project_engine =
          if is_binary(project_id) and byte_size(project_id) > 0 do
            resolve_project_engine(project_id)
          else
            nil
          end

        project_engine || agent_default_engine(binding, scope) || default_engine()
    end
  end

  defp default_engine do
    if is_pid(Process.whereis(Config)) do
      Config.get(:default_engine) || "lemon"
    else
      ConfigLoader.load()
      |> Map.get(:default_engine, "lemon")
      |> Kernel.||("lemon")
    end
  rescue
    _ -> "lemon"
  end

  defp agent_default_engine(%Binding{agent_id: agent_id} = _binding, scope)
       when is_binary(agent_id) do
    cwd = resolve_cwd(scope)
    cfg = LemonCore.Config.cached(cwd)
    profile = Map.get(cfg.agents || %{}, agent_id) || Map.get(cfg.agents || %{}, "default") || %{}

    engine =
      profile[:default_engine] || profile["default_engine"] ||
        profile[:engine] || profile["engine"]

    if is_binary(engine) and byte_size(engine) > 0, do: engine, else: nil
  rescue
    _ -> nil
  end

  defp agent_default_engine(_, _), do: nil

  @doc """
  Resolve the agent_id for a given scope.

  If no binding exists or no agent_id is set, returns "default".
  """
  @spec resolve_agent_id(ChatScope.t()) :: String.t()
  def resolve_agent_id(%ChatScope{} = scope) do
    binding = resolve_binding(scope)

    case binding && binding.agent_id do
      id when is_binary(id) and byte_size(id) > 0 -> id
      _ -> "default"
    end
  end

  defp resolve_project_engine(project_name) do
    case lookup_project(project_name) do
      %{default_engine: engine} when is_binary(engine) and byte_size(engine) > 0 -> engine
      _ -> nil
    end
  end

  @doc """
  Resolves the working directory for a given scope based on project binding.

  Returns the project root path if a binding with a project exists, nil otherwise.
  """
  @spec resolve_cwd(ChatScope.t()) :: String.t() | nil
  def resolve_cwd(%ChatScope{} = scope) do
    binding = resolve_binding(scope)
    override_id = get_project_override(scope)

    cond do
      is_binary(override_id) and byte_size(override_id) > 0 ->
        case lookup_project(override_id) do
          %{root: root} when is_binary(root) and byte_size(root) > 0 -> Path.expand(root)
          _ -> nil
        end

      binding && is_binary(binding.project) && byte_size(binding.project) > 0 ->
        case lookup_project(binding.project) do
          %{root: root} when is_binary(root) and byte_size(root) > 0 -> Path.expand(root)
          _ -> nil
        end

      true ->
        nil
    end
  end

  # Be defensive: some callers/tests use scope identifiers (strings) instead of ChatScope structs.
  def resolve_cwd(_scope), do: nil

  @doc """
  Resolves the queue mode for a given scope.

  Returns the queue_mode from the binding, or nil if no binding or queue_mode is set.
  """
  @spec resolve_queue_mode(ChatScope.t()) :: LemonGateway.Types.queue_mode() | nil
  def resolve_queue_mode(%ChatScope{} = scope) do
    binding = resolve_binding(scope)

    if binding do
      binding.queue_mode
    else
      nil
    end
  end

  defp project_id_for(%ChatScope{} = scope, %Binding{} = binding) do
    override = get_project_override(scope)

    cond do
      is_binary(override) and byte_size(override) > 0 -> override
      is_binary(binding.project) and byte_size(binding.project) > 0 -> binding.project
      true -> nil
    end
  end

  defp project_id_for(%ChatScope{} = scope, _binding) do
    override = get_project_override(scope)
    if is_binary(override) and byte_size(override) > 0, do: override, else: nil
  end

  @doc false
  def get_project_override(%ChatScope{} = scope) do
    if Code.ensure_loaded?(Store) and function_exported?(Store, :get, 2) do
      Store.get(@project_overrides_table, scope)
    else
      nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def lookup_project(project_id) when is_binary(project_id) do
    dynamic =
      if Code.ensure_loaded?(Store) and function_exported?(Store, :get, 2) do
        Store.get(@dynamic_projects_table, project_id)
      else
        nil
      end

    cond do
      is_map(dynamic) and is_binary(dynamic[:root] || dynamic["root"]) ->
        %{
          root: dynamic[:root] || dynamic["root"],
          default_engine: dynamic[:default_engine] || dynamic["default_engine"]
        }

      true ->
        projects = Config.get(:projects) || %{}

        case Map.get(projects, project_id) do
          %{root: root} = proj when is_binary(root) ->
            %{
              root: root,
              default_engine: Map.get(proj, :default_engine) || Map.get(proj, "default_engine")
            }

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  def lookup_project(_), do: nil
end
