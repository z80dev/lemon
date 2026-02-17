defmodule LemonChannels.Binding do
  @moduledoc false
  defstruct [:transport, :chat_id, :topic_id, :project, :agent_id, :default_engine, :queue_mode]

  @type t :: %__MODULE__{
          transport: atom(),
          chat_id: integer(),
          topic_id: integer() | nil,
          project: String.t() | nil,
          agent_id: String.t() | nil,
          default_engine: String.t() | nil,
          queue_mode: atom() | nil
        }
end

defmodule LemonChannels.BindingResolver do
  @moduledoc """
  Resolves bindings and settings for a Telegram chat scope.
  """

  alias LemonChannels.{Binding, GatewayConfig}
  alias LemonChannels.Types.ChatScope
  alias LemonCore.Store

  @project_overrides_table :channels_project_overrides
  @dynamic_projects_table :channels_projects_dynamic

  @spec resolve_binding(ChatScope.t()) :: Binding.t() | nil
  def resolve_binding(%ChatScope{} = scope) do
    bindings = bindings()

    topic_binding =
      if scope.topic_id do
        Enum.find(bindings, fn b ->
          get_field(b, :transport) == scope.transport and
            get_field(b, :chat_id) == scope.chat_id and
            get_field(b, :topic_id) == scope.topic_id
        end)
      else
        nil
      end

    chat_binding =
      Enum.find(bindings, fn b ->
        get_field(b, :transport) == scope.transport and
          get_field(b, :chat_id) == scope.chat_id and
          is_nil(get_field(b, :topic_id))
      end)

    normalize_binding(topic_binding || chat_binding)
  end

  defp bindings do
    GatewayConfig.get(:bindings, []) |> List.wrap()
  rescue
    _ -> []
  end

  defp get_field(%Binding{} = b, key), do: Map.get(b, key)
  defp get_field(b, key) when is_map(b), do: b[key] || Map.get(b, key)
  defp get_field(_, _), do: nil

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

  @spec resolve_engine(ChatScope.t(), String.t() | nil, map() | nil) :: String.t() | nil
  def resolve_engine(%ChatScope{} = scope, engine_hint, resume) do
    cond do
      is_map(resume) and is_binary(resume[:engine] || resume["engine"]) ->
        resume[:engine] || resume["engine"]

      is_binary(engine_hint) and String.trim(engine_hint) != "" ->
        engine_hint

      true ->
        resolve_engine_from_binding(scope)
    end
  end

  def resolve_engine(_scope, engine_hint, resume) do
    cond do
      is_map(resume) and is_binary(resume[:engine] || resume["engine"]) ->
        resume[:engine] || resume["engine"]

      is_binary(engine_hint) ->
        engine_hint

      true ->
        GatewayConfig.get(:default_engine)
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

        project_engine || agent_default_engine(binding, scope) || GatewayConfig.get(:default_engine)
    end
  end

  defp agent_default_engine(%Binding{agent_id: agent_id}, scope) when is_binary(agent_id) do
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

  @spec resolve_agent_id(ChatScope.t()) :: String.t()
  def resolve_agent_id(%ChatScope{} = scope) do
    case resolve_binding(scope) do
      %Binding{agent_id: id} when is_binary(id) and byte_size(id) > 0 -> id
      _ -> "default"
    end
  rescue
    _ -> "default"
  end

  defp resolve_project_engine(project_name) do
    case lookup_project(project_name) do
      %{default_engine: engine} when is_binary(engine) and byte_size(engine) > 0 -> engine
      _ -> nil
    end
  end

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

  def resolve_cwd(_), do: nil

  @spec resolve_queue_mode(ChatScope.t()) :: atom() | nil
  def resolve_queue_mode(%ChatScope{} = scope) do
    case resolve_binding(scope) do
      %Binding{} = binding -> binding.queue_mode
      _ -> nil
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
    Store.get(@project_overrides_table, scope)
  rescue
    _ -> nil
  end

  @doc false
  def lookup_project(project_id) when is_binary(project_id) do
    dynamic = Store.get(@dynamic_projects_table, project_id)

    cond do
      is_map(dynamic) and is_binary(dynamic[:root] || dynamic["root"]) ->
        %{
          root: dynamic[:root] || dynamic["root"],
          default_engine: dynamic[:default_engine] || dynamic["default_engine"]
        }

      true ->
        projects = GatewayConfig.get(:projects, %{}) || %{}

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
