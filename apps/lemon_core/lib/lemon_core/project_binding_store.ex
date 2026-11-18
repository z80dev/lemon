defmodule LemonCore.ProjectBindingStore do
  @moduledoc """
  Typed wrapper for per-scope project override bindings.

  An override names an operator-configured project id; projects themselves
  come only from configuration. There is no runtime-created project table.
  """

  alias LemonCore.Store

  @project_overrides :project_overrides

  @spec get_override(term()) :: term()
  def get_override(scope), do: Store.get(@project_overrides, scope)

  @spec put_override(term(), term()) :: :ok
  def put_override(scope, project_id), do: Store.put(@project_overrides, scope, project_id)

  @spec delete_override(term()) :: :ok
  def delete_override(scope), do: Store.delete(@project_overrides, scope)

  @spec list_overrides() :: list()
  def list_overrides, do: Store.list(@project_overrides)
end
