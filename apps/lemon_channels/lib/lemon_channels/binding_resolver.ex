defmodule LemonChannels.BindingResolver do
  @moduledoc """
  Bindings and settings for a chat scope, as channels need them.

  A binding maps a transport, chat and optional topic to a project, an agent
  and a queue mode. The rules live in `LemonCore.BindingResolver`; this
  module only supplies the bindings and projects from the gateway config, so
  every adapter resolves the same way with one call.
  """

  alias LemonCore.{Binding, BindingResolver, ChatScope, GatewayConfig}

  @spec resolve_binding(ChatScope.t()) :: Binding.t() | nil
  def resolve_binding(%ChatScope{} = scope), do: BindingResolver.resolve_binding(scope, opts())

  @spec resolve_agent_id(ChatScope.t()) :: String.t()
  def resolve_agent_id(%ChatScope{} = scope), do: BindingResolver.resolve_agent_id(scope, opts())

  @spec resolve_cwd(ChatScope.t() | term()) :: String.t() | nil
  def resolve_cwd(%ChatScope{} = scope), do: BindingResolver.resolve_cwd(scope, opts())
  def resolve_cwd(_), do: nil

  @spec resolve_queue_mode(ChatScope.t()) :: atom() | nil
  def resolve_queue_mode(%ChatScope{} = scope) do
    BindingResolver.resolve_queue_mode(scope, opts())
  end

  @doc false
  def get_project_override(%ChatScope{} = scope), do: BindingResolver.get_project_override(scope)

  @doc false
  def lookup_project(project_id) when is_binary(project_id) do
    BindingResolver.lookup_project(project_id, &projects/0)
  end

  def lookup_project(_), do: nil

  defp opts, do: [bindings: bindings(), config_provider: &projects/0]

  defp bindings, do: GatewayConfig.get(:bindings, []) |> List.wrap()

  defp projects, do: GatewayConfig.get(:projects, %{}) || %{}
end
