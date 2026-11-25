defmodule CodingAgent.Tools.TodoViewsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Todo

  doctest Todo

  defp todo(id, status, priority, dependencies \\ []),
    do: %{
      id: id,
      content: "Task #{id}",
      status: status,
      priority: priority,
      dependencies: dependencies
    }

  test "actionable keeps open tasks whose dependencies are completed, by priority" do
    todos = [
      todo("done", :completed, :high),
      todo("low", :pending, :low, ["done"]),
      todo("high", :in_progress, :high),
      todo("medium", :pending, :medium),
      todo("waiting", :pending, :high, ["done", "medium"]),
      todo("blocked", :blocked, :high),
      todo("dropped", :abandoned, :high)
    ]

    assert Enum.map(Todo.actionable(todos), & &1.id) == ["high", "medium", "low"]
  end

  test "progress counts every status with a whole-number percentage" do
    todos = [
      todo("1", :completed, :high),
      %{"id" => "2", "status" => "in_progress"},
      todo("3", :blocked, :low),
      %{"id" => "4", "status" => "abandoned"},
      todo("5", :pending, :low)
    ]

    assert Todo.progress(todos) ==
             %{
               total: 5,
               completed: 1,
               in_progress: 1,
               blocked: 1,
               abandoned: 1,
               pending: 1,
               percentage: 20
             }

    assert %{total: 0, percentage: 0} = Todo.progress([])
    assert %{percentage: 100} = Todo.progress([todo("1", :completed, :low)])
  end

  test "result details stringify keys and keep notes and terminal tasks in the plan" do
    todos = [
      %{
        id: "b",
        content: "Blocked",
        status: :blocked,
        blocker: "access",
        phase: "Deploy",
        priority: :high
      },
      %{"id" => "a", "content" => "Abandoned", "status" => "abandoned", "priority" => "medium"},
      %{id: "p", content: "Ready", status: :pending, priority: :low}
    ]

    details = Todo.result_details(todos)
    assert Enum.map(details.todos, & &1["status"]) == ["blocked", "abandoned", "pending"]
    assert hd(details.todos)["blocker"] == "access"

    assert details.plan.entries == [
             %{
               content: "Blocked",
               status: "blocked",
               priority: "high",
               blocker: "access",
               phase: "Deploy"
             },
             %{content: "Abandoned", status: "abandoned", priority: "medium"},
             %{content: "Ready", status: "pending", priority: "low"}
           ]

    assert Todo.actionable(todos) == [List.last(todos)]
  end

  test "normalization keeps the first active item and preserves keys, identity and priority" do
    todos = [
      %{id: "first", status: :in_progress, priority: :high},
      %{"id" => "second", "status" => "in_progress", "priority" => "low"},
      %{id: "third", status: :in_progress, priority: :medium},
      %{id: "blocked", status: :blocked}
    ]

    assert Todo.normalize(todos) == [
             hd(todos),
             %{"id" => "second", "status" => "pending", "priority" => "low"},
             %{id: "third", status: :pending, priority: :medium},
             List.last(todos)
           ]

    assert Todo.normalize([]) == []
    assert Todo.normalize([%{"status" => "pending"}]) == [%{"status" => "pending"}]
  end
end
