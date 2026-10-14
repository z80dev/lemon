defmodule CodingAgent.Session.BackgroundTasksTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.{BackgroundTasks, CompactionManager, Persistence}
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

  @tag :tmp_dir
  test "a summary applies only to its unchanged destination and live context matches resume", %{
    tmp_dir: tmp_dir
  } do
    session_manager =
      tmp_dir
      |> SessionManager.new()
      |> SessionManager.append_message(%{"role" => "user", "content" => "destination"})
      |> SessionManager.persist(Path.join(tmp_dir, "session.jsonl"))

    messages = Persistence.restore_messages_from_session(session_manager)
    agent = start_supervised!({LemonAgent.Agent, initial_state: %{messages: messages}})

    state = %{
      session_manager: session_manager,
      agent: agent,
      model: %{provider: :mock, id: "test"},
      turn_index: 1,
      is_streaming: false
    }

    signature = CompactionManager.session_signature(state)

    callbacks = %{
      broadcast_event: fn _state, _event -> :ok end,
      restore_messages_from_session: &Persistence.restore_messages_from_session/1
    }

    # A second navigation, a changed revision, or a prompt starting first all
    # invalidate the frozen destination. None may alter history or live context.
    changed_branch = %{state | session_manager: %{session_manager | leaf_id: nil}}

    changed_revision = %{
      state
      | session_manager:
          SessionManager.append_label(
            %{session_manager | file_path: nil},
            session_manager.leaf_id,
            "keep"
          )
    }

    for stale <- [changed_branch, changed_revision, %{state | is_streaming: true}] do
      assert BackgroundTasks.complete_branch_summary(
               stale,
               signature,
               "source",
               "summary",
               callbacks
             ) ==
               stale

      assert LemonAgent.Agent.get_state(agent).messages == messages
    end

    busy = %{state | is_streaming: true}
    assert {:error, :busy, ^busy} = BackgroundTasks.summarize_branch(busy, [], callbacks)

    next =
      BackgroundTasks.complete_branch_summary(state, signature, "source", "summary", callbacks)

    assert next.session_manager.leaf_id != session_manager.leaf_id

    assert SessionManager.get_entry(next.session_manager, next.session_manager.leaf_id).parent_id ==
             session_manager.leaf_id

    assert {:ok, restored} = SessionManager.load_from_file(session_manager.file_path)

    assert LemonAgent.Agent.get_state(agent).messages ==
             Persistence.restore_messages_from_session(restored)

    assert %CodingAgent.Messages.BranchSummaryMessage{summary: "summary"} =
             List.last(LemonAgent.Agent.get_state(agent).messages)
  end
end
