defmodule CodingAgent.ProgressTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Progress, Session, SessionManager}
  alias CodingAgent.Tools.Todo
  alias LemonAgent.Test.Mocks

  setup do
    cwd =
      Path.join(System.tmp_dir!(), "progress-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(cwd)
    manager = SessionManager.new(cwd)
    session_id = manager.header.id
    path = SessionManager.session_file_path(cwd, session_id)
    :ok = SessionManager.save_to_file(path, manager)

    session =
      start_supervised!(
        {Session,
         cwd: cwd,
         workspace_dir: Path.join(cwd, "workspace"),
         session_file: path,
         session_key: session_id,
         model: Mocks.mock_model(),
         tools: []}
      )

    on_exit(fn ->
      LemonCore.ChatStateStore.delete(session_id)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
      File.rm_rf!(cwd)
    end)

    {:ok, session_id: session_id, cwd: cwd, session: session}
  end

  defp write(session, todos) do
    assert %LemonAgent.Types.AgentToolResult{} =
             Todo.execute("write", %{"action" => "write", "todos" => todos}, nil, nil, session)
  end

  test "reports journal todo progress live and after the session stops", %{
    session_id: session_id,
    cwd: cwd,
    session: session
  } do
    write(session, [
      %{"id" => "t1", "content" => "Done", "status" => "completed", "priority" => "high"},
      %{"id" => "t2", "content" => "Pending", "status" => "pending", "priority" => "medium"}
    ])

    snapshot = Progress.snapshot(session_id, cwd)

    assert snapshot.todos.total == 2
    assert snapshot.todos.completed == 1
    refute Map.has_key?(snapshot, :features)
    assert snapshot.overall_percentage == 50
    assert length(snapshot.next_actions.todos) == 1
    assert Map.keys(snapshot.next_actions) == [:todos]

    stop_supervised!(Session)
    assert Progress.snapshot(session_id, cwd) == snapshot
  end

  test "a native progress read rejects a journal with another identity", %{cwd: cwd} do
    requested_id = "foreign-#{System.unique_integer([:positive])}"
    manager = SessionManager.new(cwd)
    path = SessionManager.session_file_path(cwd, requested_id)
    :ok = SessionManager.save_to_file(path, manager)

    assert {:error, :session_not_found} =
             CodingAgent.ControlPlaneProvider.native_session_todos(requested_id, cwd)

    snapshot = Progress.snapshot(requested_id, cwd)
    assert snapshot.todos == nil
    assert snapshot.next_actions.todos == []
  end
end
