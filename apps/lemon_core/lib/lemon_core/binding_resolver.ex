defmodule LemonCore.BindingResolver do
  @moduledoc """
  Canonical binding resolver shared by gateway and channels.

  Resolves bindings and settings for a given chat scope. Bindings map
  transport/chat/topic combinations to projects, engines, and queue modes.

  Both `LemonGateway.BindingResolver` and `LemonChannels.BindingResolver`
  delegate here after converting their local structs to `LemonCore` types.
  """

  alias LemonCore.Binding
  alias LemonCore.ChatScope
  alias LemonCore.Store

  @project_overrides_table :project_overrides
  @dynamic_projects_table :projects_dynamic

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a binding for the given scope.

  Returns the most specific binding that matches:
  - Topic-level binding (transport + chat_id + topic_id) takes precedence
  - Falls back to chat-level binding (transport + chat_id)
  - Returns nil if no binding matches
  """
  @spec resolve_binding(ChatScope.t(), keyword()) :: Binding.t() | nil
  def resolve_binding(%ChatScope{} = scope, opts \\ []) do
    bindings = Keyword.get(opts, :bindings, []) |> List.wrap()

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

    chat_binding =
      Enum.find(bindings, fn b ->
        get_field(b, :transport) == scope.transport &&
          get_field(b, :chat_id) == scope.chat_id &&
          is_nil(get_field(b, :topic_id))
      end)

    normalize_binding(topic_binding || chat_binding)
  end

  @doc """
  Resolves the engine to use for a given scope, hint, and resume token.

  Priority order (highest to lowest):
  1. Resume token engine (from conversation continuation)
  2. Engine hint (from /engine command)
  3. Topic binding default_engine
  4. Chat binding default_engine
  5. Project default_engine
  6. Agent profile default_engine
  7. Global default_engine from config
  """
  @spec resolve_engine(ChatScope.t(), String.t() | nil, map() | nil, keyword()) ::
          String.t() | nil
  def resolve_engine(%ChatScope{} = scope, engine_hint, resume, opts \\ []) do
    cond do
      resume_engine(resume) ->
        resume_engine(resume)

      is_binary(engine_hint) and engine_hint != "" ->
        engine_hint

      true ->
        resolve_engine_from_binding(scope, opts)
    end
  end

  @doc """
  Resolve the agent_id for a given scope.

  If no binding exists or no agent_id is set, returns "default".
  """
  @spec resolve_agent_id(ChatScope.t(), keyword()) :: String.t()
  def resolve_agent_id(%ChatScope{} = scope, opts \\ []) do
    case resolve_binding(scope, opts) do
      %Binding{agent_id: id} when is_binary(id) and byte_size(id) > 0 -> id
      _ -> "default"
    end
  rescue
    _ -> "default"
  end

  @doc """
  Resolves the working directory for a given scope based on project binding.

  Returns the project root path if a binding with a project exists, nil otherwise.
  """
  @spec resolve_cwd(ChatScope.t(), keyword()) :: String.t() | nil
  def resolve_cwd(%ChatScope{} = scope, opts \\ []) do
    binding = resolve_binding(scope, opts)
    override_id = get_project_override(scope)

    config_provider = Keyword.get(opts, :config_provider)

    cond do
      present?(override_id) ->
        case lookup_project(override_id, config_provider) do
          %{root: root} when is_binary(root) and byte_size(root) > 0 -> Path.expand(root)
          _ -> nil
        end

      binding && present?(binding.project) ->
        case lookup_project(binding.project, config_provider) do
          %{root: root} when is_binary(root) and byte_size(root) > 0 -> Path.expand(root)
          _ -> nil
        end

      true ->
        nil
    end
  end

  @doc """
  Resolves the queue mode for a given scope.

  Returns the queue_mode from the binding, or nil if no binding or queue_mode is set.
  """
  @spec resolve_queue_mode(ChatScope.t(), keyword()) :: atom() | nil
  def resolve_queue_mode(%ChatScope{} = scope, opts \\ []) do
    case resolve_binding(scope, opts) do
      %Binding{} = binding -> binding.queue_mode
      _ -> nil
    end
  end

  @doc """
  Returns the project override for a given scope from the unified store table.
  """
  @spec get_project_override(ChatScope.t()) :: String.t() | nil
  def get_project_override(%ChatScope{} = scope) do
    Store.get(@project_overrides_table, scope)
  rescue
    _ -> nil
  end

  @doc """
  Looks up a project by id from dynamic store, then static config.

  The optional `config_provider` is a 0-arity function that returns
  a `%{projects: %{...}}` map (used by gateway/channels to inject
  their own config source).
  """
  @spec lookup_project(String.t(), (-> map()) | nil) :: map() | nil
  def lookup_project(project_id, config_provider \\ nil)

  def lookup_project(project_id, config_provider) when is_binary(project_id) do
    dynamic = Store.get(@dynamic_projects_table, project_id)

    cond do
      is_map(dynamic) and is_binary(dynamic[:root] || dynamic["root"]) ->
        %{
          root: dynamic[:root] || dynamic["root"],
          default_engine: dynamic[:default_engine] || dynamic["default_engine"]
        }

      true ->
        projects =
          if is_function(config_provider, 0) do
            config_provider.() || %{}
          else
            %{}
          end

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

  def lookup_project(_, _), do: nil

  @doc "Returns the canonical project-overrides ETS table name."
  @spec project_overrides_table() :: atom()
  def project_overrides_table, do: @project_overrides_table

  @doc "Returns the canonical dynamic-projects ETS table name."
  @spec dynamic_projects_table() :: atom()
  def dynamic_projects_table, do: @dynamic_projects_table

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_engine_from_binding(scope, opts) do
    binding = resolve_binding(scope, opts)
    config_provider = Keyword.get(opts, :config_provider)
    default_engine = Keyword.get(opts, :default_engine, "lemon")

    cond do
      binding && binding.default_engine ->
        binding.default_engine

      true ->
        project_id = project_id_for(scope, binding)

        project_engine =
          if present?(project_id) do
            resolve_project_engine(project_id, config_provider)
          else
            nil
          end

        project_engine || agent_default_engine(binding, scope, opts) || default_engine
    end
  end

  defp resolve_project_engine(project_name, config_provider) do
    case lookup_project(project_name, config_provider) do
      %{default_engine: engine} when is_binary(engine) and byte_size(engine) > 0 -> engine
      _ -> nil
    end
  end

  defp agent_default_engine(%Binding{agent_id: agent_id}, scope, opts)
       when is_binary(agent_id) do
    cwd = resolve_cwd(scope, opts)
    cfg = LemonCore.Config.cached(cwd)
    profile = Map.get(cfg.agents || %{}, agent_id) || Map.get(cfg.agents || %{}, "default") || %{}

    engine =
      profile[:default_engine] || profile["default_engine"] ||
        profile[:engine] || profile["engine"]

    if present?(engine), do: engine, else: nil
  rescue
    _ -> nil
  end

  defp agent_default_engine(_, _, _), do: nil

  defp project_id_for(%ChatScope{} = scope, %Binding{} = binding) do
    override = get_project_override(scope)

    cond do
      present?(override) -> override
      present?(binding.project) -> binding.project
      true -> nil
    end
  end

  defp project_id_for(%ChatScope{} = scope, _binding) do
    override = get_project_override(scope)
    if present?(override), do: override, else: nil
  end

  defp resume_engine(%{engine: e}) when is_binary(e) and e != "", do: e
  defp resume_engine(resume) when is_map(resume) do
    e = Map.get(resume, :engine) || Map.get(resume, "engine")
    if is_binary(e) and e != "", do: e, else: nil
  end

  defp resume_engine(_), do: nil

  # Binding field access — handles both structs and plain maps
  defp get_field(%Binding{} = b, key), do: Map.get(b, key)
  defp get_field(b, key) when is_map(b), do: b[key] || Map.get(b, key)
  defp get_field(_, _), do: nil

  # Normalize to canonical Binding struct
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

  defp parse_queue_mode(nil), do: nil
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("steer_backlog"), do: :steer_backlog
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(mode) when is_atom(mode), do: mode
  defp parse_queue_mode(_), do: nil

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(val) when is_binary(val), do: byte_size(val) > 0
  defp present?(_), do: false
end
