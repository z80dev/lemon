defmodule CodingAgent.Session.BackgroundTasksTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.BackgroundTasks
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  test "branch_switch? detects jumps away from the active branch" do
    root = %SessionEntry{id: "root"}
    current_leaf = %SessionEntry{id: "leaf"}
    other_leaf = %SessionEntry{id: "other"}

    current_branch = [root, current_leaf]
    other_branch = [root, other_leaf]

    assert BackgroundTasks.branch_switch?(current_branch, other_branch, "leaf", "other")
    refute BackgroundTasks.branch_switch?(current_branch, current_branch, "leaf", "leaf")
  end

  test "store_branch_summary appends entry and broadcasts event" do
    session_manager = SessionManager.new("/tmp")
    state = %{session_manager: session_manager}
    parent = self()

    callbacks = %{
      broadcast_event: fn _state, event ->
        send(parent, {:broadcast, event})
        :ok
      end,
      ui_set_working_message: fn _, _ -> :ok end,
      ui_notify: fn _, _, _ -> :ok end
    }

    next_state = BackgroundTasks.store_branch_summary(state, "leaf-1", "summary", callbacks)

    assert SessionManager.entry_count(next_state.session_manager) == 1
    assert_received {:broadcast, {:branch_summarized, %{from_id: "leaf-1", summary: "summary"}}}
  end
end
