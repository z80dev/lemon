defmodule LemonAutomation.KanbanRunWorkerTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.KanbanRunWorker
  alias LemonCore.KanbanStore

  defmodule KanbanRouterOk do
    @moduledoc false

    def submit(params) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:router_submit, params})
      {:ok, params.run_id}
    end
  end

  defmodule KanbanRouterOtherRun do
    @moduledoc false

    def submit(params) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:router_submit, params})
      {:ok, "run_other"}
    end
  end

  defmodule KanbanRouterError do
    @moduledoc false

    def submit(_params), do: {:error, :busy}
  end

  defmodule KanbanWaiterOk do
    @moduledoc false

    def wait_already_subscribed(run_id, timeout_ms, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:wait_subscribed, run_id, timeout_ms})
      {:ok, "done"}
    end

    def wait(run_id, timeout_ms, _opts) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:wait, run_id, timeout_ms})
      {:ok, "done"}
    end
  end

  setup do
    :persistent_term.put({KanbanRouterOk, :test_pid}, self())
    :persistent_term.put({KanbanRouterOtherRun, :test_pid}, self())
    :persistent_term.put({KanbanWaiterOk, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({KanbanRouterOk, :test_pid})
      :persistent_term.erase({KanbanRouterOtherRun, :test_pid})
      :persistent_term.erase({KanbanWaiterOk, :test_pid})

      KanbanStore.list_boards(limit: 100)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
    end)

    :ok
  end

  test "builds a router request with board and task provenance" do
    {:ok, task} = sample_task()

    params = KanbanRunWorker.build_params(task, "run_kanban", model: "zai:glm-5-turbo")

    assert params.origin == :kanban
    assert params.run_id == "run_kanban"
    assert params.agent_id == task.assignee
    assert params.model == "zai:glm-5-turbo"
    assert params.cwd == "/tmp/lemon-kanban"
    assert params.tool_policy == %{blocked_tools: ["kanban"]}
    assert params.meta.kanban_board_id == task.board_id
    assert params.meta.kanban_task_id == task.id
    assert params.prompt =~ task.title
    assert params.prompt =~ "durable Lemon kanban task"
  end

  test "submits through router and waits for the expected run" do
    {:ok, task} = sample_task()

    assert {:ok, %{run_id: "run_expected"}} =
             KanbanRunWorker.run(task,
               router_mod: KanbanRouterOk,
               waiter_mod: KanbanWaiterOk,
               run_id: "run_expected",
               timeout_ms: 123
             )

    assert_receive {:router_submit, params}
    assert params.run_id == "run_expected"
    assert_receive {:wait_subscribed, "run_expected", 123}
  end

  test "submits git workspace tasks from an isolated worktree" do
    repo = tmp_git_repo!("kanban-run-worker")
    {:ok, task} = sample_task(workspace: repo)

    assert {:ok, %{run_id: "run_worktree"}} =
             KanbanRunWorker.run(task,
               router_mod: KanbanRouterOk,
               waiter_mod: KanbanWaiterOk,
               run_id: "run_worktree"
             )

    assert_receive {:router_submit, params}
    assert params.run_id == "run_worktree"
    assert params.cwd == Path.join([repo, ".worktrees", "kanban-#{task.id}"])
    assert File.exists?(Path.join(params.cwd, ".git"))
    assert File.exists?(Path.join(params.cwd, "README.md"))
    assert params.meta.kanban_worktree_root == repo
    assert params.meta.kanban_worktree_path == params.cwd
    assert params.meta.kanban_worktree_branch == "lemon-kanban/#{task.id}"
    assert_receive {:wait_subscribed, "run_worktree", _}
  end

  test "waits on the router returned run id when it differs" do
    {:ok, task} = sample_task()

    assert {:ok, %{run_id: "run_other"}} =
             KanbanRunWorker.run(task,
               router_mod: KanbanRouterOtherRun,
               waiter_mod: KanbanWaiterOk,
               run_id: "run_expected",
               timeout_ms: 456
             )

    assert_receive {:router_submit, params}
    assert params.run_id == "run_expected"
    assert_receive {:wait, "run_other", 456}
  end

  test "returns router errors for dispatcher failure marking" do
    {:ok, task} = sample_task()

    assert {:error, :busy} =
             KanbanRunWorker.run(task,
               router_mod: KanbanRouterError,
               waiter_mod: KanbanWaiterOk,
               run_id: "run_expected"
             )
  end

  defp sample_task(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, "/tmp/lemon-kanban")

    assert {:ok, board} =
             KanbanStore.create_board("Run worker board",
               workspace: workspace,
               columns: ["todo", "doing", "done"]
             )

    KanbanStore.create_task(board.id, "Implement worker",
      description: "Use LemonRouter",
      assignee: "agent_1",
      worker_profile: "senior"
    )
  end

  defp tmp_git_repo!(name) do
    root = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    assert {_output, 0} = System.cmd("git", ["-C", root, "init"], stderr_to_stdout: true)
    File.write!(Path.join(root, "README.md"), "# test\n")

    assert {_output, 0} =
             System.cmd("git", ["-C", root, "add", "README.md"], stderr_to_stdout: true)

    assert {_output, 0} =
             System.cmd(
               "git",
               [
                 "-C",
                 root,
                 "-c",
                 "user.email=lemon@example.test",
                 "-c",
                 "user.name=Lemon Test",
                 "commit",
                 "-m",
                 "init"
               ],
               stderr_to_stdout: true
             )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
