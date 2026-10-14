defmodule CodingAgent.Tools.TaskWorktreeMergeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SettingsManager
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.Params
  alias LemonAgent.Test.Mocks

  # Child session files encode the cwd in one path component, so keep the repo
  # path short instead of using ExUnit's long per-test tmp_dir names.
  setup do
    git = System.find_executable("git") || raise "Git is required for worktree tests"
    tmp_dir = Path.join(System.tmp_dir!(), "lwm-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    git!(git, repo, ["init", "-q", "-b", "main"])
    git!(git, repo, ["config", "user.name", "Worktree Test"])
    git!(git, repo, ["config", "user.email", "worktree@example.invalid"])
    repo = git!(git, repo, ["rev-parse", "--show-toplevel"])
    File.write!(Path.join(repo, "tracked.txt"), "committed\n")
    git!(git, repo, ["add", "."])
    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Initial tree"])
    %{git: git, repo: repo}
  end

  test "merge requires a worktree and a known mode", %{repo: repo} do
    for mode <- ["patch", "branch"] do
      assert {:error, message} =
               Params.validate_run_params(%{"prompt" => "Edit", "merge" => mode}, repo)

      assert message == "merge=#{mode} requires worktree: true"
    end

    assert {:error, "merge must be one of: none, patch, branch"} =
             Params.validate_run_params(
               %{"prompt" => "Edit", "worktree" => true, "merge" => "squash"},
               repo
             )

    assert {:ok, %{merge: "none", worktree: false}} =
             Params.validate_run_params(%{"prompt" => "Edit", "merge" => "none"}, repo)

    assert {:ok, %{merge: nil}} = Params.validate_run_params(%{"prompt" => "Edit"}, repo)

    tool = TaskTool.tool(repo)
    assert tool.parameters["properties"]["merge"]["enum"] == ["none", "patch", "branch"]
    assert tool.parameters["properties"]["tasks"]["items"]["properties"]["merge"]
  end

  test "patch mode from settings replays WIP and applies the child's edits end to end", %{
    git: git,
    repo: repo
  } do
    File.write!(Path.join(repo, "tracked.txt"), "parent wip\n")
    File.write!(Path.join(repo, "notes.txt"), "parent untracked\n")
    owner = self()

    # The fake child acts like a writing tool call: it edits files in its worktree.
    stream_fn = fn model, context, options ->
      [worktree] = Path.wildcard(Path.join(repo, ".git/lemon-task-worktrees/*"))

      send(
        owner,
        {:child_saw, File.read!(Path.join(worktree, "tracked.txt")),
         File.read!(Path.join(worktree, "notes.txt"))}
      )

      File.write!(Path.join(worktree, "child.txt"), "from child\n")
      File.write!(Path.join(worktree, "tracked.txt"), "parent wip\nchild edit\n")

      Mocks.mock_stream_fn_single(Mocks.assistant_message("Edited files.")).(
        model,
        context,
        options
      )
    end

    result =
      TaskTool.execute(
        unique_id(),
        %{
          "prompt" => "Edit files",
          "worktree" => true,
          "async" => false,
          "auto_followup" => false
        },
        nil,
        nil,
        repo,
        opts(stream_fn, settings("patch"))
      )

    assert_receive {:child_saw, "parent wip\n", "parent untracked\n"}
    assert result.details.merge.mode == "patch"
    assert result.details.merge.status == "applied"
    assert Enum.sort(result.details.merge.files) == ["child.txt", "tracked.txt"]
    assert visible_text(result) =~ "Edited files."

    assert visible_text(result) =~
             "Merged task changes into the parent checkout (patch, 2 files)."

    assert File.read!(Path.join(repo, "child.txt")) == "from child\n"
    assert File.read!(Path.join(repo, "tracked.txt")) == "parent wip\nchild edit\n"
    assert File.read!(Path.join(repo, "notes.txt")) == "parent untracked\n"
    refute File.exists?(result.details.worktree_path)
    refute branch_exists?(git, repo, result.details.branch)

    assert {:ok, record, _events} = TaskStore.get(result.details.task_id)
    assert record.workspace.merge.status == "applied"
  end

  test "an explicit merge overrides settings and an idle child reports no changes", %{
    git: git,
    repo: repo
  } do
    stream_fn = Mocks.mock_stream_fn_single(Mocks.assistant_message("Nothing to change."))

    result =
      TaskTool.execute(
        unique_id(),
        %{
          "prompt" => "Inspect",
          "worktree" => true,
          "merge" => "branch",
          "async" => false,
          "auto_followup" => false
        },
        nil,
        nil,
        repo,
        opts(stream_fn, settings("patch"))
      )

    assert result.details.merge == %{mode: "branch", status: "no_changes"}
    assert visible_text(result) =~ "No task changes to merge"
    refute File.exists?(result.details.worktree_path)
    refute branch_exists?(git, repo, result.details.branch)
  end

  test "default none keeps the worktree and branch without finalizing", %{git: git, repo: repo} do
    stream_fn = Mocks.mock_stream_fn_single(Mocks.assistant_message("Done."))

    result =
      TaskTool.execute(
        unique_id(),
        %{"prompt" => "Inspect", "worktree" => true, "async" => false, "auto_followup" => false},
        nil,
        nil,
        repo,
        opts(stream_fn, %SettingsManager{})
      )

    refute Map.has_key?(result.details, :merge)
    refute visible_text(result) =~ "merge"
    assert File.dir?(result.details.worktree_path)
    assert branch_exists?(git, repo, result.details.branch)
  end

  test "a failed child skips merging and keeps its worktree", %{git: git, repo: repo} do
    stream_fn = fn _model, _context, _options -> {:error, "provider unavailable"} end

    assert {:error, _reason} =
             TaskTool.execute(
               unique_id(),
               %{
                 "prompt" => "Edit",
                 "worktree" => true,
                 "merge" => "patch",
                 "async" => false,
                 "auto_followup" => false
               },
               nil,
               nil,
               repo,
               opts(stream_fn, %SettingsManager{})
             )

    [worktree] = Path.wildcard(Path.join(repo, ".git/lemon-task-worktrees/*"))
    task_id = Path.basename(worktree)
    assert branch_exists?(git, repo, "lemon/task-#{task_id}")
    assert {:ok, record, _events} = TaskStore.get(task_id)
    assert record.workspace.merge.status == "skipped"
  end

  defp opts(stream_fn, settings) do
    [
      parent_session: unique_id(),
      model: "openai-codex:gpt-6.1-sol",
      settings_manager: settings,
      stream_fn: stream_fn
    ]
  end

  defp settings(mode) do
    default = %SettingsManager{}
    %{default | task: Map.put(default.task, :worktree_merge, mode)}
  end

  defp visible_text(result), do: CodingAgent.Tools.Task.Result.visible_output_text(result)

  defp branch_exists?(git, cwd, branch) do
    {_output, status} =
      System.cmd(git, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
        cd: cwd,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp git!(git, cwd, args) do
    {output, status} = System.cmd(git, args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, "Git command failed: #{inspect(args)}: #{output}"
    String.trim_trailing(output, "\n")
  end

  defp unique_id, do: "merge-#{System.unique_integer([:positive, :monotonic])}"
end
