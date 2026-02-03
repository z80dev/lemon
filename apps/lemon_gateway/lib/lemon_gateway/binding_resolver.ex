defmodule LemonGateway.Binding do
  @moduledoc false
  defstruct [:transport, :chat_id, :topic_id, :project, :default_engine, :queue_mode]

  @type t :: %__MODULE__{
          transport: atom(),
          chat_id: integer(),
          topic_id: integer() | nil,
          project: String.t() | nil,
          default_engine: String.t() | nil,
          queue_mode: LemonGateway.Types.queue_mode() | nil
        }
end

defmodule LemonGateway.BindingResolver do
  @moduledoc """
  Resolves bindings and settings for a given chat scope.

  Bindings map transport/chat/topic combinations to projects, engines, and queue modes.
  """

  alias LemonGateway.{Binding, Config}
  alias LemonGateway.Types.ChatScope

  @doc """
  Resolves a binding for the given scope.

  Returns the most specific binding that matches:
  - Topic-level binding (transport + chat_id + topic_id) takes precedence
  - Falls back to chat-level binding (transport + chat_id)
  - Returns nil if no binding matches
  """
  @spec resolve_binding(ChatScope.t()) :: Binding.t() | nil
  def resolve_binding(%ChatScope{} = scope) do
    bindings = Config.get(:bindings) || []

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

  defp resolve_engine_from_binding(scope) do
    binding = resolve_binding(scope)

    cond do
      binding && binding.default_engine ->
        binding.default_engine

      binding && binding.project ->
        resolve_project_engine(binding.project) || Config.get(:default_engine)

      true ->
        Config.get(:default_engine)
    end
  end

  defp resolve_project_engine(project_name) do
    projects = Config.get(:projects) || %{}

    case Map.get(projects, project_name) do
      %{default_engine: engine} when is_binary(engine) -> engine
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

    if binding && binding.project do
      projects = Config.get(:projects) || %{}

      case Map.get(projects, binding.project) do
        %{root: root} when is_binary(root) -> Path.expand(root)
        _ -> nil
      end
    else
      nil
    end
  end

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
end
