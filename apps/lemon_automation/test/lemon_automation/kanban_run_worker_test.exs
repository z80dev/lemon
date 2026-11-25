defmodule LemonAutomation.KanbanRunWorkerTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.KanbanRunWorker
  alias LemonAutomation.KanbanStore

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
    board = KanbanStore.get_board(task.board_id)

    assert {:ok, params} =
             KanbanRunWorker.build_params(task, "run_kanban", model: "zai:glm-5-turbo")

    assert params.origin == :kanban
    assert params.run_id == "run_kanban"
    assert params.agent_id == task.assignee
    assert params.model == "zai:glm-5-turbo"
    assert params.cwd == board.workspace

    for tool <- ~w(kanban goal cron),
        do: refute(LemonCore.ToolPolicy.allowed?(params.tool_policy, tool))

    assert LemonCore.ToolPolicy.allowed?(params.tool_policy, "bash")
    assert params.meta.kanban_board_id == task.board_id
    assert params.meta.kanban_task_id == task.id
    assert params.prompt =~ task.title
    assert params.prompt =~ "durable Lemon kanban task"
  end

  test "a board without recorded authority builds no request" do
    {:ok, board} = KanbanStore.create_board("Quarantined", workspace: System.tmp_dir!())
    {:ok, task} = KanbanStore.create_task(board.id, "Unauthorized")
    assert {:error, :kanban_authority_missing} = KanbanRunWorker.build_params(task, "run_x")
  end

  test "submits through router and waits for the expected run" do
    {:ok, task} = sample_task()

    assert {:ok, %{run_id: "run_expected", output: "done"}} =
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
    {:ok, expected_cwd} = LemonAutomation.KanbanWorktree.path_for(task)
    assert params.cwd == expected_cwd
    refute String.starts_with?(params.cwd, repo)
    assert is_map(params.meta.cwd_identity)
    assert File.exists?(Path.join(params.cwd, ".git"))
    assert File.exists?(Path.join(params.cwd, "README.md"))
    assert File.stat!(params.meta.kanban_worktree_root).inode == File.stat!(repo).inode
    assert params.meta.kanban_worktree_path == params.cwd
    assert params.meta.kanban_worktree_branch == "lemon-kanban/#{task.id}"
    assert_receive {:wait_subscribed, "run_worktree", _}
  end

  test "rejects a router run id mismatch without opening a racy second wait" do
    {:ok, task} = sample_task()

    assert {:outcome_unknown, "run_expected"} =
             KanbanRunWorker.run(task,
               router_mod: KanbanRouterOtherRun,
               waiter_mod: KanbanWaiterOk,
               run_id: "run_expected",
               timeout_ms: 456
             )

    assert_receive {:router_submit, params}
    assert params.run_id == "run_expected"
    refute_receive {:wait, "run_other", 456}
    refute_receive {:wait_subscribed, _, _}
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
    workspace =
      Keyword.get_lazy(opts, :workspace, fn ->
        dir = Path.join(System.tmp_dir!(), "lemon-kanban-#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf!(dir) end)
        dir
      end)

    {:ok, authority} =
      LemonAutomation.KanbanAuthority.new(
        %{agent_id: "agent_1", session_key: "agent:agent_1:main"},
        nil,
        workspace
      )

    assert {:ok, board} =
             KanbanStore.create_board("Run worker board",
               workspace: workspace,
               columns: ["todo", "doing", "done"],
               authority: authority
             )

    # Non-Git sample workspaces run in place only with the operator grant.
    digest = LemonAutomation.KanbanAuthority.workspace_digest(board.workspace)
    assert {:ok, _} = KanbanStore.grant_in_place(board.id, digest)

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
