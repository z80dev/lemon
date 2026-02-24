defmodule CodingAgent.ProgressTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Progress
  alias CodingAgent.Tools.{FeatureRequirements, TodoStore}

  setup do
    session_id = "progress-#{System.unique_integer([:positive, :monotonic])}"
    cwd = Path.join(System.tmp_dir!(), "progress-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(cwd)

    on_exit(fn ->
      TodoStore.put(session_id, [])
      _ = File.rm_rf(cwd)
    end)

    {:ok, session_id: session_id, cwd: cwd}
  end

  test "returns todo-based progress when no requirements file exists", %{session_id: session_id, cwd: cwd} do
    TodoStore.put(session_id, [
      %{id: "t1", content: "Done", status: :completed, dependencies: [], priority: :high},
      %{id: "t2", content: "Pending", status: :pending, dependencies: [], priority: :medium}
    ])

    snapshot = Progress.snapshot(session_id, cwd)

    assert snapshot.todos.total == 2
    assert snapshot.todos.completed == 1
    assert snapshot.features == nil
    assert snapshot.overall_percentage == 50
    assert length(snapshot.next_actions.todos) == 1
    assert snapshot.next_actions.features == []
  end

  test "combines todo and feature percentages when requirements exist", %{session_id: session_id, cwd: cwd} do
    TodoStore.put(session_id, [
      %{id: "t1", content: "Done", status: :completed, dependencies: [], priority: :high},
      %{id: "t2", content: "Done2", status: :completed, dependencies: [], priority: :high},
      %{id: "t3", content: "Pending", status: :pending, dependencies: [], priority: :low}
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
