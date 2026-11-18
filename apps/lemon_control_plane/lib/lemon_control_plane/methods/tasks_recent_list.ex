defmodule LemonControlPlane.Methods.TasksRecentList do
  @moduledoc """
  Handler for `tasks.recent.list`.

  Lists completed/error/timeout/aborted task records. Descriptions, results,
  reasoning, events and records need `operator.content`; read-only callers get
  metadata.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "tasks.recent.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.TaskList.handle(params, :recent, ctx)
end
