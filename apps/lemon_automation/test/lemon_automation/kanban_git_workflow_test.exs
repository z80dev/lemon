defmodule LemonAutomation.KanbanGitWorkflowTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{KanbanGitWorkflow, KanbanWorktree}

  setup do
    if Process.whereis(LemonAutomation.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: LemonAutomation.TaskSupervisor})
    end

    directory = Path.join(System.tmp_dir!(), "kanban-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    git!(directory, ["init", "-b", "main"])
    # Git supplies the physical path (macOS temporary directories can be aliases).
    root = git!(directory, ["rev-parse", "--show-toplevel"])
    git!(root, ["config", "user.name", "Kanban Test"])
    git!(root, ["config", "user.email", "kanban@example.invalid"])
    File.write!(Path.join(root, "file.txt"), "initial\n")
    File.write!(Path.join(root, ".gitignore"), ".worktrees/\nignored.txt\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "initial"])
    # Worktrees live in the shared Lemon-owned base, so task ids are unique.
    board = board(root)
    task = %{id: "review-test-#{System.unique_integer([:positive])}", board_id: board.id}
    on_exit(fn -> File.rm_rf!(elem(KanbanWorktree.path_for(task), 1)) end)
    on_exit(fn -> File.rm_rf!(elem(KanbanWorktree.controller_path(task), 1)) end)
    # The local bare test remote `bare_remote!/1` creates; `allow/1` pins it.
    Process.put(:pinned_remote, Path.join(root, "local-remote.git"))
    assert {:ok, workspace} = KanbanWorktree.prepare(task, board)
    assert {:ok, config} = KanbanGitWorkflow.normalize(%{})
    assert {:ok, checkpoint} = KanbanGitWorkflow.prepare(workspace, task, config)
    %{root: root, workspace: workspace, task: task, checkpoint: checkpoint, config: config}
  end

  # Worktree preparation requires the board's recorded authority and root; the
  # board id (derived from the root) names its controller repository.
  defp board(root) do
    {:ok, authority} =
      LemonAgent.Workspace.KanbanAuthority.new(
        %{agent_id: "default", session_key: "agent:default:main"},
        nil,
        root
      )

    id = "board-" <> String.slice(Base.encode16(:crypto.hash(:sha256, root), case: :lower), 0, 16)
    %{id: id, workspace: root, meta: %{"kanbanAuthority" => authority}}
  end

  test "normalization is explicit and rejects unsafe or unknown input" do
    assert {:ok, nil} = KanbanGitWorkflow.normalize(nil)
    assert {:ok, nil} = KanbanGitWorkflow.normalize(false)
    assert {:ok, %{review_model: nil, publish: nil}} = KanbanGitWorkflow.normalize(%{})
    assert {:error, :invalid_workflow} = KanbanGitWorkflow.normalize(true)
    assert {:error, :unknown_workflow_key} = KanbanGitWorkflow.normalize(%{"push" => true})
    assert {:error, :invalid_review_model} = KanbanGitWorkflow.normalize(%{"reviewModel" => " "})

    assert {:error, :duplicate_workflow_key} =
             KanbanGitWorkflow.normalize(%{"publish" => false, publish: false})

    for publish <- [
          true,
          %{"mode" => "branch"},
          %{"mode" => "branch", "remote" => "--all"},
          %{"mode" => "pull_request", "remote" => "origin"},
          %{"mode" => "branch", "remote" => "origin", "force" => true},
          %{
            "mode" => "pull_request",
            "remote" => "origin",
            "repository" => "owner/repo",
            "base" => "main:other"
          }
        ] do
      assert {:error, _} = KanbanGitWorkflow.normalize(%{"publish" => publish})
    end

    assert {:ok, %{publish: %{mode: :pull_request, draft: true}}} =
             KanbanGitWorkflow.normalize(%{
               "publish" => %{
                 "mode" => "pull_request",
                 "remote" => "origin",
                 "repository" => "owner/repo",
                 "base" => "main"
               }
             })
  end

  test "isolated commit contains the reviewed tree and never pushes by default", context do
    remote = bare_remote!(context.root)
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "reviewed\n")
    File.write!(Path.join(context.workspace.cwd, "new.txt"), "new\n")
    File.write!(Path.join(context.workspace.cwd, "ignored.txt"), "not reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    assert snapshot["changed"]
    assert snapshot["diff"] =~ "+reviewed"
    assert snapshot["diff"] =~ "+new"
    refute snapshot["diff"] =~ "not reviewed"

    assert {:ok, sha} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "Reviewed work", allow())

    assert git!(context.workspace.cwd, ["rev-parse", "HEAD^{tree}"]) == snapshot["tree"]
    assert git!(context.workspace.cwd, ["status", "--porcelain"]) == ""
    assert git!(context.root, ["show", "HEAD:file.txt"]) == "initial"

    assert {:ok, %{"published" => false}} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               context.config,
               "Reviewed",
               "body"
             )

    assert git!(remote, ["for-each-ref", "--format=%(refname)"]) == ""

    assert {:ok, ^sha} =
             KanbanGitWorkflow.reconcile_commit(context.checkpoint, Map.delete(snapshot, "diff"))
  end

  test "preexisting coding commits remain in review against saved base", context do
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "committed by coding run\n")
    git!(context.workspace.cwd, ["add", "-A"])
    # The worker's own Git (here without global configuration) names itself.
    git!(context.workspace.cwd, [
      "-c",
      "user.name=Coder",
      "-c",
      "user.email=coder@example.invalid",
      "commit",
      "-m",
      "coding run"
    ])

    assert {:ok, saved} =
             KanbanGitWorkflow.prepare(context.workspace, context.task, context.config,
               checkpoint: context.checkpoint
             )

    assert saved == context.checkpoint
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(saved)
    assert snapshot["diff"] =~ "+committed by coding run"
    assert {:ok, sha} = KanbanGitWorkflow.commit(saved, snapshot, "Reviewed", allow())
    assert sha == snapshot["headCommit"]
  end

  test "unchanged trees cannot become successful reviewed commits", context do
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    refute snapshot["changed"]

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "Nothing", allow())
  end

  test "tracked, staged and untracked edits after review fail without deleting changes",
       context do
    path = Path.join(context.workspace.cwd, "file.txt")
    File.write!(path, "reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    File.write!(path, "later\n")

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "No", allow())

    assert File.read!(path) == "later\n"
    git!(context.workspace.cwd, ["add", "file.txt"])

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "No", allow())

    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    File.write!(Path.join(context.workspace.cwd, "late.txt"), "late\n")

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "No", allow())

    assert git!(context.workspace.cwd, ["rev-parse", "HEAD"]) == context.checkpoint["baseCommit"]

    assert {:error, :commit_outcome_unknown} =
             KanbanGitWorkflow.reconcile_commit(context.checkpoint, snapshot)
  end

  test "binary and oversized review diffs fail closed", context do
    path = Path.join(context.workspace.cwd, "file.txt")
    File.write!(path, <<0, 1, 2, 3>>)
    assert {:error, :unreviewable_diff} = KanbanGitWorkflow.snapshot(context.checkpoint)
    File.write!(path, String.duplicate("large line\n", 20_000))
    assert {:error, :diff_too_large} = KanbanGitWorkflow.snapshot(context.checkpoint)
  end

  test "isolation checks reject wrong branch, root, symlink aliases and unrelated directories",
       context do
    assert {:error, :invalid_worktree} =
             KanbanGitWorkflow.prepare(
               %{cwd: context.root, worktree: nil},
               context.task,
               context.config
             )

    wrong = put_in(context.workspace, [:worktree, :branch], "main")

    assert {:error, :invalid_worktree} =
             KanbanGitWorkflow.prepare(wrong, context.task, context.config)

    assert {:error, :invalid_checkpoint} =
             KanbanGitWorkflow.prepare(context.workspace, context.task, context.config,
               checkpoint: Map.put(context.checkpoint, "root", "/other")
             )

    alias_path = Path.join(context.root, "alias")
    File.ln_s!(context.workspace.cwd, alias_path)

    assert {:error, :invalid_worktree} =
             KanbanWorktree.prepare(context.task, board(context.root), worktree_path: alias_path)

    # A worktree checked out on another branch than the requested one.
    assert {:error, :worktree_metadata_changed} =
             KanbanWorktree.prepare(context.task, board(context.root), worktree_branch: "main")

    unrelated = Path.join(context.root, "unrelated")
    File.mkdir_p!(unrelated)
    git!(unrelated, ["init", "-b", "main"])

    assert {:error, :invalid_worktree} =
             KanbanWorktree.prepare(context.task, board(context.root), worktree_path: unrelated)
  end

  test "explicit branch publication pushes only the owned ref to a local bare remote", context do
    remote = bare_remote!(context.root)
    {snapshot, sha} = reviewed_commit!(context)
    git_dir = context.checkpoint["gitDir"]

    assert {:ok, _} =
             KanbanGitWorkflow.controller_git(
               %{git_dir: git_dir, common_dir: git_dir, work_tree: nil},
               ["tag", "not-to-push", sha]
             )

    config = %{publish: %{mode: :branch, remote: "origin"}}

    assert {:ok, %{"published" => true, "prUrl" => nil}} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               config,
               "Reviewed",
               "body",
               allow()
             )

    assert git!(remote, ["for-each-ref", "--format=%(refname)"]) ==
             "refs/heads/" <> context.checkpoint["branch"]

    assert git!(remote, ["rev-parse", "refs/heads/" <> context.checkpoint["branch"]]) == sha

    assert {:ok, %{"published" => true}} =
             KanbanGitWorkflow.reconcile_publication(context.checkpoint, sha, config, allow())

    assert {:ok, ^sha} = KanbanGitWorkflow.reconcile_commit(context.checkpoint, snapshot)
  end

  test "PR creation uses exact argv, draft default, and independently observed matching PR",
       context do
    bare_remote!(context.root)
    {_snapshot, sha} = reviewed_commit!(context)
    owner = self()
    {:ok, state} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    runner = fn
      "gh", ["pr", "list" | _] = args, _opts ->
        send(owner, {:gh, args})
        entries = if Agent.get(state, & &1), do: [pr(context, sha)], else: []
        {:ok, Jason.encode!(entries)}

      "gh", ["pr", "create" | _] = args, _opts ->
        send(owner, {:gh, args})
        Agent.update(state, fn _ -> true end)
        {:ok, "https://github.com/owner/repo/pull/12\n"}

      program, args, opts ->
        KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
    end

    config = pr_config()

    assert {:ok, %{"published" => true, "prUrl" => "https://github.com/owner/repo/pull/12"}} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               config,
               "Reviewed title",
               "Reviewed body",
               allow(runner: runner)
             )

    assert_receive {:gh, ["pr", "list" | _]}

    assert_receive {:gh,
                    [
                      "pr",
                      "create",
                      "--repo",
                      "owner/repo",
                      "--head",
                      "lemon-kanban/" <> _,
                      "--base",
                      "main",
                      "--title",
                      "Reviewed title",
                      "--body",
                      "Reviewed body",
                      "--draft"
                    ]}

    assert_receive {:gh, ["pr", "list" | _]}

    assert {:ok, %{"published" => true}} =
             KanbanGitWorkflow.reconcile_publication(
               context.checkpoint,
               sha,
               config,
               allow(runner: runner)
             )

    assert_receive {:gh, ["pr", "list" | _]}
    refute_receive {:gh, ["pr", "create" | _]}
  end

  test "existing matching PR is reused and invalid create URLs remain ambiguous", context do
    bare_remote!(context.root)
    {_snapshot, sha} = reviewed_commit!(context)
    owner = self()

    existing = fn
      "gh", ["pr", "list" | _], _opts ->
        {:ok, Jason.encode!([pr(context, sha)])}

      "gh", args, _opts ->
        send(owner, {:unexpected_gh, args})
        {:error, :unexpected_command}

      program, args, opts ->
        KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
    end

    assert {:ok, %{"prUrl" => "https://github.com/owner/repo/pull/12"}} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               pr_config(),
               "Reviewed",
               "body",
               allow(runner: existing)
             )

    refute_receive {:unexpected_gh, _}

    for url <- [
          "http://github.com/owner/repo/pull/12",
          "https://github.com/other/repo/pull/12",
          "not a URL"
        ] do
      invalid = fn
        "gh", ["pr", "list" | _], _opts ->
          {:ok, "[]"}

        "gh", ["pr", "create" | _], _opts ->
          {:ok, url}

        program, args, opts ->
          KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
      end

      assert {:error, :publication_outcome_unknown} =
               KanbanGitWorkflow.publish(
                 context.checkpoint,
                 sha,
                 pr_config(),
                 "Reviewed",
                 "body",
                 allow(runner: invalid)
               )
    end
  end

  test "failed dispatched push is ambiguous and reconciliation never mutates", context do
    bare_remote!(context.root)
    {_snapshot, sha} = reviewed_commit!(context)
    owner = self()

    runner = fn program, args, opts ->
      if program == "git" and "push" in args do
        send(owner, :push)
        {:error, :command_timeout}
      else
        KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
      end
    end

    config = %{publish: %{mode: :branch, remote: "origin"}}

    assert {:error, :publication_outcome_unknown} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               config,
               "Reviewed",
               "body",
               allow(runner: runner)
             )

    assert_receive :push

    assert {:error, :publication_outcome_unknown} =
             KanbanGitWorkflow.reconcile_publication(
               context.checkpoint,
               sha,
               config,
               allow(runner: runner)
             )

    refute_receive :push
    forbidden = fn _, _, _ -> flunk("disabled publication dispatched a command") end

    assert {:ok, %{"published" => false}} =
             KanbanGitWorkflow.publish(nil, nil, nil, nil, nil, runner: forbidden)
  end

  # Port mechanics; `env: []` is the explicit (inherited) environment that the
  # sandboxed `git/3` and `gh/2` wrappers otherwise supply.
  test "command output is bounded and timed-out OS processes are reaped", context do
    assert {:error, :sandbox_unavailable} = KanbanGitWorkflow.command("git", ["--version"])

    assert {:error, :output_too_large} =
             KanbanGitWorkflow.command("git", ["--version"], max_output_bytes: 1, env: [])

    script = sleeper!(context.root)
    pid_path = Path.join(context.root, "timeout.pid")

    assert {:error, :command_timeout} =
             KanbanGitWorkflow.command(script, [pid_path], timeout_ms: 1_000, env: [])

    pid = File.read!(pid_path)
    assert {:error, :git_failed} = KanbanGitWorkflow.command("kill", ["-0", pid], env: [])
  end

  test "worker death terminates its supervised OS command", context do
    script = sleeper!(context.root)
    pid_path = Path.join(context.root, "owner.pid")
    worker = spawn(fn -> KanbanGitWorkflow.command(script, [pid_path], env: []) end)
    assert_eventually(fn -> File.exists?(pid_path) and File.read!(pid_path) != "" end)
    pid = File.read!(pid_path)
    Process.exit(worker, :kill)

    assert_eventually(fn ->
      match?({:error, :git_failed}, KanbanGitWorkflow.command("kill", ["-0", pid], env: []))
    end)
  end

  test "hidden index flags cannot bypass reviewed worktree checks", context do
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    git!(context.workspace.cwd, ["update-index", "--assume-unchanged", "file.txt"])
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "hidden edit\n")

    assert {:error, :changed_after_review} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "No", allow())
  end

  test "repository configuration cannot run programs during preparation, staging or commit",
       context do
    marker = Path.join(context.root, "../marker-#{System.unique_integer([:positive])}")
    marker = Path.expand(marker)
    on_exit(fn -> File.rm_rf!(marker) end)
    script = Path.join(context.root, "evil.sh")
    File.write!(script, "#!/bin/sh\necho \"$0 $*\" >> '#{marker}'\ncat\n")
    File.chmod!(script, 0o755)
    hooks = Path.join(context.root, "evil-hooks")
    File.mkdir_p!(hooks)

    for hook <-
          ~w(post-checkout pre-commit post-commit reference-transaction post-index-change pre-push) do
      File.cp!(script, Path.join(hooks, hook))
      File.cp!(script, Path.join([context.root, ".git", "hooks", hook]))
    end

    File.write!(Path.join(context.root, ".gitattributes"), "* filter=evil diff=evil merge=evil\n")
    File.write!(Path.join(context.root, ".gitignore"), "evil.sh\nevil-hooks/\n.worktrees/\n")
    git!(context.root, ["add", ".gitattributes", ".gitignore"])
    git!(context.root, ["commit", "-m", "attributes"])

    for {key, value} <- [
          {"filter.evil.clean", script},
          {"filter.evil.smudge", script},
          {"filter.evil.process", script},
          {"filter.evil.required", "true"},
          {"diff.evil.textconv", script},
          {"diff.evil.command", script},
          {"merge.evil.driver", script},
          {"core.fsmonitor", script},
          {"core.hooksPath", hooks},
          {"core.pager", script},
          {"core.editor", script},
          {"core.sshCommand", script},
          {"credential.helper", "!" <> script},
          {"gpg.program", script},
          {"commit.gpgSign", "true"}
        ] do
      git!(context.root, ["config", key, value])
    end

    task = %{
      id: "sandbox-test-#{System.unique_integer([:positive])}",
      board_id: context.task.board_id
    }

    on_exit(fn -> File.rm_rf!(elem(KanbanWorktree.path_for(task), 1)) end)
    assert {:ok, workspace} = KanbanWorktree.prepare(task, board(context.root))
    assert {:ok, checkpoint} = KanbanGitWorkflow.prepare(workspace, task, context.config)
    File.write!(Path.join(workspace.cwd, "file.txt"), "staged through a filter?\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(checkpoint)
    assert snapshot["diff"] =~ "+staged through a filter?"
    assert {:ok, _sha} = KanbanGitWorkflow.commit(checkpoint, snapshot, "Sandboxed", allow())

    refute File.exists?(marker)

    # A push URL using a command-running transport (`ext::`) is never a
    # publication destination.
    git!(context.root, ["config", "protocol.ext.allow", "always"])
    git!(context.root, ["remote", "add", "ext", "ext::#{script} %S"])

    assert {:error, :publication_destination_unavailable} =
             KanbanGitWorkflow.resolve_destinations(context.root, %{
               "mode" => "branch",
               "remote" => "ext"
             })

    refute File.exists?(marker)

    # The configuration is live: an unsanitized Git runs it immediately.
    System.cmd(
      "sh",
      ["-c", "git -C \"$1\" commit --allow-empty -m unsandboxed </dev/null", "sh", context.root],
      stderr_to_stdout: true
    )

    assert File.read!(marker) =~ "evil"
  end

  test "configuration rewritten between inspection and execution never runs a program",
       context do
    marker = Path.expand(Path.join(context.root, "../race-#{System.unique_integer([:positive])}"))
    on_exit(fn -> File.rm_rf!(marker) end)
    script = Path.join(context.root, "evil.sh")
    File.write!(script, "#!/bin/sh\necho \"$0 $*\" >> '#{marker}'\ncat\n")
    File.chmod!(script, 0o755)
    hooks = Path.join(context.root, "evil-hooks")
    File.mkdir_p!(hooks)

    for hook <- ~w(post-checkout pre-commit post-commit reference-transaction post-index-change),
        do: File.cp!(script, Path.join(hooks, hook))

    File.write!(Path.join(context.root, ".gitattributes"), "* filter=evil diff=evil\n")
    File.write!(Path.join(context.root, ".gitignore"), "evil*\n.worktrees/\n")
    git!(context.root, ["add", ".gitattributes", ".gitignore"])
    git!(context.root, ["commit", "-m", "attributes"])

    evil_section = """
    [core]
    \tfsmonitor = #{script}
    \thooksPath = #{hooks}
    \tpager = #{script}
    [filter "evil"]
    \tclean = #{script}
    \tsmudge = #{script}
    \tprocess = #{script}
    \trequired = true
    [diff "evil"]
    \ttextconv = #{script}
    [uploadpack]
    \tpackObjectsHook = #{script}
    """

    # A repository the worktree's `.git` file is redirected to.
    evil_repo = Path.join(context.root, "evil-repo")
    File.mkdir_p!(evil_repo)

    task = %{
      id: "race-test-#{System.unique_integer([:positive])}",
      board_id: context.task.board_id
    }

    {:ok, worktree} = KanbanWorktree.path_for(task)
    on_exit(fn -> File.rm_rf!(worktree) end)
    # It mimics the task's branch with a commit, so only the controller's own
    # records (not branch or HEAD checks) tell the two apart.
    git!(evil_repo, ["init", "-b", KanbanWorktree.branch_for(task)])
    File.write!(Path.join(evil_repo, "file.txt"), "initial\n")
    git!(evil_repo, ["add", "file.txt"])

    git!(evil_repo, [
      "-c",
      "user.name=Evil",
      "-c",
      "user.email=evil@example.invalid",
      "commit",
      "-m",
      "mimic"
    ])

    evil_git = Path.join(evil_repo, ".git")

    File.write!(
      Path.join(evil_git, "config"),
      File.read!(Path.join(evil_git, "config")) <> evil_section
    )

    root_config = Path.join([context.root, ".git", "config"])
    clean_root_config = File.read!(root_config)

    # Immediately before every controller command (after any inspection), the
    # workspace repository's configuration and the worktree's `.git` file are
    # rewritten to name programs.
    arm = fn ->
      File.write!(root_config, clean_root_config <> evil_section)

      if File.dir?(worktree),
        do: File.write!(Path.join(worktree, ".git"), "gitdir: #{evil_git}\n")
    end

    runner = fn program, args, opts ->
      arm.()
      KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
    end

    prepared = KanbanWorktree.prepare(task, board(context.root), runner: runner)

    checkpoint =
      with {:ok, workspace} <- prepared,
           {:ok, checkpoint} <-
             KanbanGitWorkflow.prepare(workspace, task, context.config, runner: runner) do
        checkpoint
      end

    File.write!(Path.join(worktree, "file.txt"), "raced\n")
    snapshotted = KanbanGitWorkflow.snapshot(checkpoint, runner: runner)

    committed =
      with {:ok, snapshot} <- snapshotted,
           do: KanbanGitWorkflow.commit(checkpoint, snapshot, "Raced", allow(runner: runner))

    # No program ran at any step, whatever the steps returned...
    refute File.exists?(marker)
    # ...and every step succeeded against the controller repository.
    assert {:ok, _} = prepared
    assert {:ok, %{"diff" => diff}} = snapshotted
    assert diff =~ "+raced"
    assert {:ok, sha} = committed
    # The commit landed in the controller repository, not the redirected one.
    assert File.read!(Path.join(worktree, ".git")) == "gitdir: #{evil_git}\n"
    git_dir = checkpoint["gitDir"]

    assert {:ok, head} =
             KanbanGitWorkflow.controller_git(
               %{git_dir: git_dir, common_dir: git_dir, work_tree: nil},
               ["rev-parse", "refs/heads/" <> checkpoint["branch"]]
             )

    assert String.trim(head) == sha

    # Both rewrites are live: an unsanitized Git in the worktree runs them.
    System.cmd("sh", ["-c", "git -C \"$1\" status </dev/null", "sh", worktree],
      stderr_to_stdout: true
    )

    assert File.read!(marker) =~ "evil"
  end

  test "worktree administrative metadata changed by other means is refused", context do
    alias LemonAutomation.KanbanGitSandbox

    marker =
      Path.expand(Path.join(context.root, "../admin-#{System.unique_integer([:positive])}"))

    on_exit(fn -> File.rm_rf!(marker) end)
    script = Path.join(context.root, "evil.sh")
    File.write!(script, "#!/bin/sh\necho \"$0 $*\" >> '#{marker}'\ncat\n")
    File.chmod!(script, 0o755)
    %{"gitDir" => git_dir, "cwd" => cwd, "branch" => branch} = context.checkpoint

    # The worktree's administrative directory, from the repository's records.
    {:ok, %{git_dir: admin} = repo} = KanbanGitSandbox.worktree_repo(git_dir, cwd, branch)

    # A prepared look-alike common directory whose configuration defines a
    # clean filter, which the worktree's (worker-written) attributes select.
    evil = Path.join(context.root, "evil-common.git")
    {_, 0} = System.cmd("git", ["clone", "-q", "--bare", git_dir, evil], stderr_to_stdout: true)
    filter = "[filter \"evil\"]\n\tclean = #{script}\n"
    File.write!(Path.join(evil, "config"), File.read!(Path.join(evil, "config")) <> filter)
    File.write!(Path.join(cwd, ".gitattributes"), "* filter=evil\n")
    File.write!(Path.join(cwd, "file.txt"), "changed\n")

    for {file, content} <- [
          {"commondir", evil <> "\n"},
          {"HEAD", "ref: refs/heads/main\n"},
          {"config.worktree", filter}
        ] do
      path = Path.join(admin, file)
      original = File.read(path)
      File.write!(path, content)

      assert {:error, :invalid_checkpoint} = KanbanGitWorkflow.snapshot(context.checkpoint), file

      assert {:error, :worktree_metadata_changed} =
               KanbanGitWorkflow.validate_context(git_dir, cwd, branch),
             file

      assert {:error, :worktree_metadata_changed} =
               KanbanGitWorkflow.controller_git(repo, ["status", "--porcelain"]),
             file

      case original do
        {:ok, bytes} -> File.write!(path, bytes)
        {:error, :enoent} -> File.rm!(path)
      end
    end

    refute File.exists?(marker)
    assert {:ok, %{"diff" => diff}} = KanbanGitWorkflow.snapshot(context.checkpoint)
    assert diff =~ "+changed"

    # Git's common directory is always the verified controller repository,
    # never what an administrative `commondir` file names.
    assert {:ok, env} = KanbanGitSandbox.controller_env(repo, [])
    assert {~c"GIT_COMMON_DIR", String.to_charlist(git_dir)} in env
    assert {~c"GIT_DIR", String.to_charlist(admin)} in env
  end

  test "controller repository configuration is verified before every command", context do
    git_dir = context.checkpoint["gitDir"]
    config = Path.join(git_dir, "config")
    File.write!(config, File.read!(config) <> "[core]\n\tfsmonitor = /bin/false\n")

    assert {:error, :invalid_checkpoint} = KanbanGitWorkflow.snapshot(context.checkpoint)

    assert {:error, :controller_config_changed} =
             KanbanWorktree.prepare(context.task, board(context.root))

    assert {:error, :controller_config_changed} =
             KanbanGitWorkflow.controller_git(
               %{git_dir: git_dir, common_dir: git_dir, work_tree: nil},
               ["rev-parse", "HEAD"]
             )
  end

  test "publication pushes only to the pinned destination, never a changed remote", context do
    pinned = bare_remote!(context.root)
    other = Path.join(context.root, "other-remote.git")
    File.mkdir_p!(other)
    git!(other, ["init", "--bare"])
    {_snapshot, sha} = reviewed_commit!(context)
    config = %{publish: %{mode: :branch, remote: "origin"}}

    # After the grant pinned `pinned`, the remote is redirected; then, after
    # the plan was built, redirected again (URL rewriting) before the push.
    git!(context.root, ["config", "remote.origin.pushurl", other])

    runner = fn program, args, opts ->
      if "push" in args,
        do: git!(context.root, ["config", "url.#{other}.pushInsteadOf", pinned])

      KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
    end

    assert {:ok, %{"published" => true}} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               config,
               "Reviewed",
               "body",
               allow(runner: runner, destinations: [pinned])
             )

    assert git!(pinned, ["rev-parse", "refs/heads/" <> context.checkpoint["branch"]]) == sha
    assert git!(other, ["for-each-ref", "--format=%(refname)"]) == ""

    # A fresh grant would show (and bind) the changed destination instead.
    assert {:ok, %{"push" => [^other]}} =
             KanbanGitWorkflow.resolve_destinations(context.root, %{
               "mode" => "branch",
               "remote" => "origin"
             })

    # Without granted destinations nothing is published.
    assert {:error, :publication_not_authorized} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               config,
               "Reviewed",
               "body",
               allow(destinations: nil)
             )
  end

  test "in-place execution needs an operator grant for exactly the workspace", context do
    alias LemonAgent.Workspace.KanbanAuthority

    plain = Path.join(System.tmp_dir!(), "plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    {:ok, plain} = KanbanAuthority.canonical_directory(plain)
    plain_board = board(plain)
    task = %{id: "in-place-#{System.unique_integer([:positive])}", board_id: plain_board.id}
    on_exit(fn -> File.rm_rf!(elem(KanbanWorktree.path_for(task), 1)) end)
    %{meta: %{"kanbanAuthority" => authority}} = plain_board
    with_authority = &%{&1 | meta: %{"kanbanAuthority" => &2}}

    # A non-Git workspace, or worktrees turned off in a repository.
    assert {:error, :in_place_execution_not_authorized} =
             KanbanWorktree.prepare(task, plain_board)

    repo_task = %{task | board_id: context.task.board_id}

    assert {:error, :in_place_execution_not_authorized} =
             KanbanWorktree.prepare(repo_task, board(context.root), worktree_mode: :off)

    # A grant names one workspace and does not transfer.
    {:ok, elsewhere} = KanbanAuthority.grant_in_place(authority, context.root)

    assert {:error, :in_place_execution_not_authorized} =
             KanbanWorktree.prepare(task, with_authority.(plain_board, elsewhere))

    {:ok, granted} = KanbanAuthority.grant_in_place(authority, plain)

    assert {:ok, %{cwd: ^plain, worktree: nil}} =
             KanbanWorktree.prepare(task, with_authority.(plain_board, granted))

    # Controller repository refusals never fall back to running in place.
    %{meta: %{"kanbanAuthority" => repo_authority}} = repo_board = board(context.root)
    {:ok, repo_granted} = KanbanAuthority.grant_in_place(repo_authority, context.root)
    config = Path.join(context.checkpoint["gitDir"], "config")
    File.write!(config, File.read!(config) <> "[core]\n\tpager = cat\n")

    assert {:error, :controller_config_changed} =
             KanbanWorktree.prepare(repo_task, with_authority.(repo_board, repo_granted))
  end

  test "commands are authorized exactly as run, before any of them runs", context do
    bare_remote!(context.root)
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)
    head = git!(context.workspace.cwd, ["rev-parse", "HEAD"])

    # No authorizer, or a denied commit message argument: nothing is written.
    assert {:error, :commit_not_authorized} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "Fix the fixture")

    assert {:error, :commit_not_authorized} =
             KanbanGitWorkflow.commit(
               context.checkpoint,
               snapshot,
               "Fix the fixture",
               allow(authorize: deny_text("-m Fix the fixture"))
             )

    assert git!(context.workspace.cwd, ["rev-parse", "HEAD"]) == head
    {_snapshot, sha} = reviewed_commit!(context)
    owner = self()

    runner = fn program, args, opts ->
      send(owner, {:ran, program, args})

      if program == "gh",
        do: {:ok, "[]"},
        else: KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
    end

    seen = fn command ->
      send(owner, {:authorized, command})
      :ok
    end

    # Every command the publication runs was authorized first, in full.
    assert {:ok, %{"published" => true}} =
             KanbanGitWorkflow.publish(
               context.checkpoint,
               sha,
               %{publish: %{mode: :branch, remote: "origin"}},
               "Reviewed",
               "body",
               allow(runner: runner, authorize: seen)
             )

    authorized = drain(:authorized)
    ran = drain(:ran)

    for {"git", ["-C", _cwd | args]} <- ran,
        hd(args) in ["push", "ls-remote", "remote"],
        do: assert({"git", args} in authorized)

    assert Enum.any?(authorized, &match?({"git", ["ls-remote", "--refs", "--", _, _]}, &1))

    # One denied argument (an ls-remote, a PR base) refuses before the network.
    for {config, denied} <- [
          {%{publish: %{mode: :branch, remote: "origin"}}, "git ls-remote"},
          {pr_config(), "--base main"},
          {pr_config(), "gh pr list"}
        ] do
      assert {:error, :publication_not_authorized} =
               KanbanGitWorkflow.publish(
                 context.checkpoint,
                 sha,
                 config,
                 "Reviewed",
                 "body",
                 allow(runner: runner, authorize: deny_text(denied))
               )

      assert {:error, :publication_not_authorized} =
               KanbanGitWorkflow.reconcile_publication(
                 context.checkpoint,
                 sha,
                 config,
                 allow(runner: runner, authorize: deny_text(denied))
               )

      ran = drain(:ran)
      refute Enum.any?(ran, fn {program, args} -> program == "gh" or "push" in args end)
      refute Enum.any?(ran, fn {_program, args} -> "ls-remote" in args end)
    end
  end

  defp deny_text(fragment) do
    fn command ->
      if LemonAgent.Workspace.KanbanAuthority.command_text(command) =~ fragment,
        do: {:error, :denied},
        else: :ok
    end
  end

  defp drain(tag, acc \\ []) do
    receive do
      {^tag, program, args} -> drain(tag, [{program, args} | acc])
      {^tag, command} -> drain(tag, [command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sleeper!(root) do
    script = Path.join(root, "sleeper")
    File.write!(script, "#!/bin/sh\nprintf '%s' \"$$\" > \"$1\"\nexec sleep 30\n")
    File.chmod!(script, 0o700)
    script
  end

  defp assert_eventually(fun, attempts \\ 250)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp reviewed_commit!(context) do
    File.write!(Path.join(context.workspace.cwd, "file.txt"), "reviewed\n")
    assert {:ok, snapshot} = KanbanGitWorkflow.snapshot(context.checkpoint)

    assert {:ok, sha} =
             KanbanGitWorkflow.commit(context.checkpoint, snapshot, "Reviewed", allow())

    {snapshot, sha}
  end

  defp bare_remote!(root) do
    path = Path.join(root, "local-remote.git")
    File.mkdir_p!(path)
    git!(path, ["init", "--bare"])
    git!(root, ["remote", "add", "origin", path])
    path
  end

  defp pr_config,
    do: %{
      publish: %{mode: :pull_request, remote: "origin", repository: "owner/repo", base: "main"}
    }

  defp pr(context, sha),
    do: %{
      "url" => "https://github.com/owner/repo/pull/12",
      "headRefName" => context.checkpoint["branch"],
      "baseRefName" => "main",
      "headRefOid" => sha,
      "isCrossRepository" => false
    }

  # Trusted controller options: an authorizer that admits every command, the
  # `file` transport and the granted (pinned) local bare test remote.
  defp allow(extra \\ []),
    do:
      Keyword.merge(
        [
          authorize: fn _command -> :ok end,
          allowed_protocols: ["file"],
          destinations: [Process.get(:pinned_remote)]
        ],
        extra
      )

  defp git!(cwd, args) do
    assert {:ok, output} = KanbanGitWorkflow.git(cwd, args)
    String.trim(output)
  end
end
