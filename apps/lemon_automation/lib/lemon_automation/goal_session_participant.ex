defmodule LemonAutomation.GoalSessionParticipant do
  @moduledoc """
  `LemonCore.SessionLifecycle.Participant` for the session goal: deleting a
  session clears its goal (emitting `:goal_cleared`, which stops goal loops).
  Reset keeps the goal; it states what the session is working toward, not
  conversation content.
  """

  @behaviour LemonCore.SessionLifecycle.Participant

  alias LemonAutomation.GoalStore
  alias LemonCore.SessionLifecycle.StoreRows

  @impl true
  def snapshot(session_key, :delete),
    do: StoreRows.snapshot(session_key, GoalStore.lifecycle_tables())

  @impl true
  def delete(session_key, :delete, _rows),
    do: GoalStore.clear(session_key, record_introspection: false)

  @impl true
  def verify_deleted(session_key, :delete, rows),
    do: StoreRows.verify_deleted(session_key, GoalStore.lifecycle_tables(), rows)

  @impl true
  def restore(_session_key, :delete, rows), do: StoreRows.restore(rows)
end
