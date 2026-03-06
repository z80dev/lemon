defmodule LemonCore.ProjectBindingStore do
  @moduledoc """
  Typed wrapper for project binding tables.
  """

  alias LemonCore.Store

  @project_overrides :project_overrides
  @projects_dynamic :projects_dynamic

  @spec get_override(binary()) :: term()
  def get_override(project_id), do: Store.get(@project_overrides, project_id)

  @spec put_override(binary(), map()) :: :ok
  def put_override(project_id, value), do: Store.put(@project_overrides, project_id, value)

  @spec delete_override(binary()) :: :ok
  def delete_override(project_id), do: Store.delete(@project_overrides, project_id)

  @spec list_overrides() :: list()
  def list_overrides, do: Store.list(@project_overrides)

  @spec get_dynamic(binary()) :: term()
  def get_dynamic(project_id), do: Store.get(@projects_dynamic, project_id)

  @spec put_dynamic(binary(), map()) :: :ok
  def put_dynamic(project_id, value), do: Store.put(@projects_dynamic, project_id, value)

  @spec delete_dynamic(binary()) :: :ok
  def delete_dynamic(project_id), do: Store.delete(@projects_dynamic, project_id)

  @spec list_dynamic() :: list()
  def list_dynamic, do: Store.list(@projects_dynamic)
end
