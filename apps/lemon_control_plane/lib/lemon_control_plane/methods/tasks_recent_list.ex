defmodule LemonControlPlane.Methods.TasksRecentList do
  @moduledoc """
  Handler for `tasks.recent.list`.

  Lists completed/error/timeout/aborted task records with TaskStore internals.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "tasks.recent.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx), do: LemonControlPlane.Methods.TaskList.handle(params, :recent)
end
