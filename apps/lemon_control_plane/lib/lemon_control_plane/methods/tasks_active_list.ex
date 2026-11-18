defmodule LemonControlPlane.Methods.TasksActiveList do
  @moduledoc """
  Handler for `tasks.active.list`.

  Lists active task/subagent records. Descriptions, results, reasoning, events
  and records need `operator.content`; read-only callers get metadata.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "tasks.active.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.TaskList.handle(params, :active, ctx)
end
