defmodule LemonCore.BindingResolver do
  @moduledoc """
  Canonical binding resolver shared by gateway and channels.

  Resolves bindings and settings for a given chat scope. Bindings map
  transport/chat/topic combinations to projects and queue modes.

  `LemonChannels.BindingResolver` calls these with the bindings and projects
  from the gateway config; the gateway resolves through the same functions.
  """

  alias LemonCore.Binding
  alias LemonCore.ChatScope
  alias LemonCore.ProjectBindingStore

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
    ProjectBindingStore.get_override(scope)
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
    dynamic = ProjectBindingStore.get_dynamic(project_id)

    cond do
      is_map(dynamic) and is_binary(dynamic[:root] || dynamic["root"]) ->
        %{root: dynamic[:root] || dynamic["root"]}

      true ->
        projects =
          if is_function(config_provider, 0) do
            config_provider.() || %{}
          else
            %{}
          end

        case Map.get(projects, project_id) do
          %{root: root} when is_binary(root) ->
            %{root: root}

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  def lookup_project(_, _), do: nil

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
