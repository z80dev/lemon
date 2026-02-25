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

  Thin delegation layer that converts channels-local structs to
  `LemonCore` types and delegates to `LemonCore.BindingResolver`.
  """

  alias LemonChannels.{Binding, GatewayConfig}
  alias LemonCore.ChatScope
  alias LemonCore.BindingResolver, as: CoreResolver

  # ---------------------------------------------------------------------------
  # Public API — same signatures as before
  # ---------------------------------------------------------------------------

  @spec resolve_binding(ChatScope.t()) :: Binding.t() | nil
  def resolve_binding(%ChatScope{} = scope) do
    scope
    |> to_core_scope()
    |> CoreResolver.resolve_binding(resolver_opts())
    |> from_core_binding()
  end

  @spec resolve_engine(ChatScope.t(), String.t() | nil, map() | nil) :: String.t() | nil
  def resolve_engine(%ChatScope{} = scope, engine_hint, resume) do
    scope
    |> to_core_scope()
    |> CoreResolver.resolve_engine(engine_hint, resume, resolver_opts())
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

  @spec resolve_agent_id(ChatScope.t()) :: String.t()
  def resolve_agent_id(%ChatScope{} = scope) do
    scope
    |> to_core_scope()
    |> CoreResolver.resolve_agent_id(resolver_opts())
  end

  @spec resolve_cwd(ChatScope.t()) :: String.t() | nil
  def resolve_cwd(%ChatScope{} = scope) do
    scope
    |> to_core_scope()
    |> CoreResolver.resolve_cwd(resolver_opts())
  end

  def resolve_cwd(_), do: nil

  @spec resolve_queue_mode(ChatScope.t()) :: atom() | nil
  def resolve_queue_mode(%ChatScope{} = scope) do
    scope
    |> to_core_scope()
    |> CoreResolver.resolve_queue_mode(resolver_opts())
  end

  @doc false
  def get_project_override(%ChatScope{} = scope) do
    scope
    |> to_core_scope()
    |> CoreResolver.get_project_override()
  end

  @doc false
  def lookup_project(project_id) when is_binary(project_id) do
    CoreResolver.lookup_project(project_id, &config_projects/0)
  end

  def lookup_project(_), do: nil

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolver_opts do
    [
      bindings: bindings(),
      config_provider: &config_projects/0,
      default_engine: GatewayConfig.get(:default_engine) || "lemon"
    ]
  end

  defp to_core_scope(%ChatScope{} = s) do
    %LemonCore.ChatScope{transport: s.transport, chat_id: s.chat_id, topic_id: s.topic_id}
  end

  defp from_core_binding(nil), do: nil

  defp from_core_binding(%LemonCore.Binding{} = b) do
    %Binding{
      transport: b.transport,
      chat_id: b.chat_id,
      topic_id: b.topic_id,
      project: b.project,
      agent_id: b.agent_id,
      default_engine: b.default_engine,
      queue_mode: b.queue_mode
    }
  end

  defp bindings do
    GatewayConfig.get(:bindings, []) |> List.wrap()
  rescue
    _ -> []
  end

  defp config_projects do
    GatewayConfig.get(:projects, %{}) || %{}
  rescue
    _ -> %{}
  end
end
