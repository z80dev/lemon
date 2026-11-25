defmodule LemonWeb.SessionParticipant do
  @moduledoc """
  `LemonCore.SessionLifecycle.Participant` for the web workspace: deleting a
  session forgets the workspace `LemonWeb.SessionCwd.remember/2` recorded for
  it. Reset keeps it; the session still runs in the same workspace.
  """

  @behaviour LemonCore.SessionLifecycle.Participant

  alias LemonCore.SessionLifecycle.StoreRows
  alias LemonWeb.SessionCwd

  @impl true
  def snapshot(session_key, :delete),
    do: StoreRows.snapshot(session_key, SessionCwd.lifecycle_tables())

  @impl true
  def delete(_session_key, :delete, rows), do: StoreRows.delete(rows)

  @impl true
  def verify_deleted(session_key, :delete, rows),
    do: StoreRows.verify_deleted(session_key, SessionCwd.lifecycle_tables(), rows)

  @impl true
  def restore(_session_key, :delete, rows), do: StoreRows.restore(rows)
end
