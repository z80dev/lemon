defmodule CodingAgent.ProgressTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Progress, Session, SessionManager}
  alias CodingAgent.Tools.{FeatureRequirements, TodoStore, TodoWrite}
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
      TodoStore.delete(session_id)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
      File.rm_rf!(cwd)
    end)

    {:ok, session_id: session_id, cwd: cwd, session: session}
  end

  defp write(session, todos) do
    assert %LemonAgent.Types.AgentToolResult{} =
             TodoWrite.execute("write", %{"todos" => todos}, nil, nil, session)
  end

  test "returns todo-based progress when no requirements file exists", %{
    session_id: session_id,
    cwd: cwd,
    session: session
  } do
    write(session, [
      %{"id" => "t1", "content" => "Done", "status" => "completed", "priority" => "high"},
      %{"id" => "t2", "content" => "Pending", "status" => "pending", "priority" => "medium"}
    ])

    TodoStore.delete(Session.get_state(session).session_manager.header.id)

    snapshot = Progress.snapshot(session_id, cwd)

    assert snapshot.todos.total == 2
    assert snapshot.todos.completed == 1
    assert snapshot.features == nil
    assert snapshot.overall_percentage == 50
    assert length(snapshot.next_actions.todos) == 1
    assert snapshot.next_actions.features == []

    stop_supervised!(Session)
    TodoStore.delete(session_id)
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

  test "combines todo and feature percentages when requirements exist", %{
    session_id: session_id,
    cwd: cwd,
    session: session
  } do
    write(session, [
      %{"id" => "t1", "content" => "Done", "status" => "completed", "priority" => "high"},
      %{"id" => "t2", "content" => "Done2", "status" => "completed", "priority" => "high"},
      %{"id" => "t3", "content" => "Pending", "status" => "pending", "priority" => "low"}
    ])

    requirements = %{
      project_name: "Long run",
      original_prompt: "build thing",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      version: "1.0",
      features: [
        %{
          id: "f1",
          description: "Feature 1",
          status: :completed,
          dependencies: [],
          priority: :high,
          acceptance_criteria: ["works"],
          notes: "",
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: nil
        },
        %{
          id: "f2",
          description: "Feature 2",
          status: :pending,
          dependencies: ["f1"],
          priority: :medium,
          acceptance_criteria: ["works"],
          notes: "",
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: nil
        }
      ]
    }

    assert :ok = FeatureRequirements.save_requirements(requirements, cwd)

    snapshot = Progress.snapshot(session_id, cwd)

    assert snapshot.todos.percentage == 66
    assert snapshot.features.percentage == 50
    assert snapshot.overall_percentage == 60
    assert Enum.any?(snapshot.next_actions.features, &(&1.id == "f2"))
  end
end
