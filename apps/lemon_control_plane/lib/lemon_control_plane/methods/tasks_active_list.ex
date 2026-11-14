defmodule LemonControlPlane.Methods.TasksActiveList do
  @moduledoc """
  Handler for `tasks.active.list`.

  Lists active task/subagent records with TaskStore internals.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "tasks.active.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx), do: LemonControlPlane.Methods.TaskList.handle(params, :active)
end
