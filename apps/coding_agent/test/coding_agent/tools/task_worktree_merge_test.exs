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
      assert {:error, _} =
               Params.validate_run_params(%{"prompt" => "Edit", "merge" => mode}, repo)
    end

    assert {:error, _} =
             Params.validate_run_params(
               %{"prompt" => "Edit", "worktree" => true, "merge" => "squash"},
               repo
             )

    assert {:ok, _} = Params.validate_run_params(%{"prompt" => "Edit", "merge" => "none"}, repo)
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
    assert result.details.merge.status == "applied"
    assert Enum.sort(result.details.merge.files) == ["child.txt", "tracked.txt"]
    assert visible_text(result) =~ "Edited files."

    assert File.read!(Path.join(repo, "child.txt")) == "from child\n"
    assert File.read!(Path.join(repo, "tracked.txt")) == "parent wip\nchild edit\n"
    assert File.read!(Path.join(repo, "notes.txt")) == "parent untracked\n"
    refute File.exists?(result.details.worktree_path)
    refute branch_exists?(git, repo, result.details.branch)

    assert {:ok, record, _events} = TaskStore.get(result.details.task_id)
    assert record.workspace.merge.status == "applied"
  end

  test "default merge retains child work without changing the parent", %{git: git, repo: repo} do
    owner = self()

    stream_fn = fn model, context, options ->
      [worktree] = Path.wildcard(Path.join(repo, ".git/lemon-task-worktrees/*"))
      File.write!(Path.join(worktree, "tracked.txt"), "child work\n")
      send(owner, {:default_child, worktree})
      Mocks.mock_stream_fn_single(Mocks.assistant_message("Edited.")).(model, context, options)
    end

    # Exercise core config resolution as well as the runtime settings default.
    task_settings = LemonCore.Config.Agent.resolve(%{}).task

    result =
      TaskTool.execute(
        unique_id(),
        %{"prompt" => "Edit", "worktree" => true, "async" => false, "auto_followup" => false},
        nil,
        nil,
        repo,
        opts(stream_fn, %{%SettingsManager{} | task: task_settings})
      )

    assert_receive {:default_child, worktree}
    assert File.read!(Path.join(repo, "tracked.txt")) == "committed\n"
    assert File.read!(Path.join(worktree, "tracked.txt")) == "child work\n"
    assert branch_exists?(git, repo, result.details.branch)
    assert git!(git, repo, ["status", "--porcelain"]) == ""
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
    refute File.exists?(result.details.worktree_path)
    refute branch_exists?(git, repo, result.details.branch)
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

  for mode <- ["patch", "branch"], state <- ["staged", "committed"] do
    test "public task retains a #{state} pointer-only gitlink in #{mode} mode", %{
      git: git,
      repo: repo
    } do
      mode = unquote(mode)
      state = unquote(state)
      pin = local_submodule(git, repo)
      File.write!(Path.join(repo, "tracked.txt"), "parent staged\n")
      git!(git, repo, ["add", "tracked.txt"])
      File.write!(Path.join(repo, "tracked.txt"), "parent unstaged\n")
      File.write!(Path.join(repo, "notes.txt"), "parent untracked\n")
      parent_head = git!(git, repo, ["rev-parse", "HEAD"])
      parent_index = git!(git, repo, ["write-tree"])
      parent_status = git!(git, repo, ["status", "--porcelain=v1", "-z"])
      command = "git update-index --cacheinfo 160000,#{pin},vendor"

      command =
        if state == "committed" do
          command <>
            " && git -c core.hooksPath=/dev/null commit -qm 'Child gitlink pin'"
        else
          command
        end

      # The provider scripts an actual bash tool invocation, not an echoed
      # success or a replacement finalizer. Git and the child session run normally.
      stream_fn = fn model, context, options ->
        response =
          if Enum.any?(context.messages, &(Map.get(&1, :role) == :tool_result)) do
            Mocks.assistant_message("Finished pinning the local dependency.")
          else
            Mocks.assistant_message_with_tool_calls([
              Mocks.tool_call("bash", %{"command" => command})
            ])
          end

        Mocks.mock_stream_fn_single(response).(model, context, options)
      end

      result =
        TaskTool.execute(
          unique_id(),
          %{
            "prompt" => "Pin the local dependency",
            "worktree" => true,
            "merge" => mode,
            "tool_policy" => %{"allow" => "all"},
            "async" => false,
            "auto_followup" => false
          },
          nil,
          nil,
          repo,
          opts(stream_fn, settings("none"))
        )

      assert result.details.merge.status == "error"
      assert result.details.merge.mode == mode
      worktree = result.details.worktree_path
      branch = result.details.branch
      assert File.dir?(worktree)
      assert branch_exists?(git, repo, branch)
      assert git!(git, worktree, ["rev-parse", ":vendor"]) == pin
      assert git!(git, worktree, ["symbolic-ref", "--short", "HEAD"]) == branch

      if state == "committed" do
        assert git!(git, repo, ["rev-parse", "#{branch}:vendor"]) == pin
        assert git!(git, worktree, ["diff", "--cached", "--name-only"]) == ""
      else
        assert git!(git, worktree, [
                 "diff",
                 "--cached",
                 "--name-only",
                 "--ignore-submodules=none",
                 "HEAD"
               ]) == "vendor"
      end

      assert git!(git, repo, ["rev-parse", "HEAD"]) == parent_head
      assert git!(git, repo, ["write-tree"]) == parent_index
      assert git!(git, repo, ["status", "--porcelain=v1", "-z"]) == parent_status
      assert File.read!(Path.join(repo, "tracked.txt")) == "parent unstaged\n"
      assert File.read!(Path.join(repo, "notes.txt")) == "parent untracked\n"
      assert File.read!(Path.join(repo, "vendor/version.txt")) == "original\n"
      assert {:ok, record, _events} = TaskStore.get(result.details.task_id)
      assert record.workspace.merge == result.details.merge
    end
  end

  for mode <- ["patch", "branch"] do
    test "public task retains an initialized submodule checkout git add skips in #{mode} mode",
         %{git: git, repo: repo} do
      mode = unquote(mode)
      pin = local_submodule(git, repo)
      # Committed `.gitmodules` filters make git add skip the moved checkout.
      git!(git, repo, ["config", "--file", ".gitmodules", "submodule.vendor.ignore", "all"])
      git!(git, repo, ["add", ".gitmodules"])
      git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Ignore vendor"])
      old_pin = git!(git, repo, ["rev-parse", "HEAD:vendor"])
      File.write!(Path.join(repo, "tracked.txt"), "parent staged\n")
      git!(git, repo, ["add", "tracked.txt"])
      File.write!(Path.join(repo, "tracked.txt"), "parent unstaged\n")
      File.write!(Path.join(repo, "notes.txt"), "parent untracked\n")
      parent_head = git!(git, repo, ["rev-parse", "HEAD"])
      parent_index = git!(git, repo, ["write-tree"])
      status = ["status", "--porcelain=v1", "-z", "--ignore-submodules=none"]
      parent_status = git!(git, repo, status)

      # The child really initializes its submodule and moves its HEAD, beside an
      # ordinary edit that would otherwise be applied or committed on its own.
      command =
        "git -c protocol.file.allow=always submodule update --init -q -- vendor" <>
          " && git -C vendor checkout -q --detach #{pin}" <>
          " && printf 'from child\\n' > child.txt"

      stream_fn = fn model, context, options ->
        response =
          if Enum.any?(context.messages, &(Map.get(&1, :role) == :tool_result)) do
            Mocks.assistant_message("Finished updating the local dependency.")
          else
            Mocks.assistant_message_with_tool_calls([
              Mocks.tool_call("bash", %{"command" => command})
            ])
          end

        Mocks.mock_stream_fn_single(response).(model, context, options)
      end

      result =
        TaskTool.execute(
          unique_id(),
          %{
            "prompt" => "Update the local dependency",
            "worktree" => true,
            "merge" => mode,
            "tool_policy" => %{"allow" => "all"},
            "async" => false,
            "auto_followup" => false
          },
          nil,
          nil,
          repo,
          opts(stream_fn, settings("none"))
        )

      assert result.details.merge.status == "error"
      assert result.details.merge.mode == mode
      worktree = result.details.worktree_path
      branch = result.details.branch
      assert File.dir?(worktree)
      assert branch_exists?(git, repo, branch)
      assert git!(git, worktree, ["symbolic-ref", "--short", "HEAD"]) == branch
      assert git!(git, repo, ["rev-parse", branch]) == git!(git, worktree, ["rev-parse", "HEAD"])
      assert git!(git, repo, ["rev-parse", "#{branch}:vendor"]) == old_pin
      assert git!(git, repo, ["ls-tree", "--name-only", branch, "--", "child.txt"]) == ""
      assert git!(git, worktree, ["rev-parse", ":vendor"]) == old_pin
      assert git!(git, Path.join(worktree, "vendor"), ["rev-parse", "HEAD"]) == pin
      assert File.read!(Path.join(worktree, "child.txt")) == "from child\n"
      assert git!(git, worktree, status) == " M vendor\0?? child.txt\0"
      assert git!(git, repo, ["rev-parse", "HEAD"]) == parent_head
      assert git!(git, repo, ["write-tree"]) == parent_index
      assert git!(git, repo, status) == parent_status

      refute File.exists?(Path.join(repo, "child.txt"))
      assert File.read!(Path.join(repo, "tracked.txt")) == "parent unstaged\n"
      assert File.read!(Path.join(repo, "notes.txt")) == "parent untracked\n"
      assert git!(git, Path.join(repo, "vendor"), ["rev-parse", "HEAD"]) == old_pin
      assert {:ok, record, _events} = TaskStore.get(result.details.task_id)
      assert record.workspace.merge == result.details.merge
    end
  end

  defp local_submodule(git, repo) do
    source = Path.join(Path.dirname(repo), "vendor-source")
    File.mkdir_p!(source)
    git!(git, source, ["init", "-q", "-b", "main"])
    git!(git, source, ["config", "user.name", "Worktree Test"])
    git!(git, source, ["config", "user.email", "worktree@example.invalid"])
    File.write!(Path.join(source, "version.txt"), "original\n")
    git!(git, source, ["add", "."])
    git!(git, source, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Original vendor"])

    git!(git, repo, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "--",
      source,
      "vendor"
    ])

    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Pin local vendor"])
    File.write!(Path.join(source, "version.txt"), "updated\n")
    git!(git, source, ["add", "."])
    git!(git, source, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Update vendor"])
    git!(git, source, ["rev-parse", "HEAD"])
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
