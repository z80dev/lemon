# Run from the umbrella root: mix run --no-start scripts/task_worktrees_smoke.exs
# No ExUnit, network, credentials or replacement finalizer. The scripted provider
# invokes the real child bash tool; assertions inspect Git and public task results.
defmodule LemonScripts.TaskWorktreesSmoke do
  alias CodingAgent.SettingsManager
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task, as: TaskTool
  alias LemonAi.Types.{AssistantMessage, TextContent, ToolCall, Usage}

  def main do
    if Process.whereis(CodingAgent.TaskStoreServer) || Process.whereis(LemonCore.Store) do
      raise "Run this smoke in a fresh VM with mix run --no-start"
    end

    root = Path.join(System.tmp_dir!(), "ltw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))

    Application.put_env(:lemon_core, :store_runtime_override,
      backend: LemonCore.Store.EtsBackend,
      backend_opts: []
    )

    Application.put_env(:lemon_core, LemonCore.RunHistoryStore, path: Path.join(root, "history"))
    Application.put_env(:coding_agent, :task_store_path, Path.join(root, "tasks.dets"))
    Application.put_env(:coding_agent, :run_graph_path, Path.join(root, "runs.dets"))
    {:ok, started} = Application.ensure_all_started(:coding_agent)

    try do
      git = System.find_executable("git") || raise "Git is required"

      for mode <- ["patch", "branch"],
          scenario <- ["staged", "committed", "initialized", "empty", "files"] do
        run_case(git, root, mode, scenario)
        IO.puts("PASS TaskWorktrees #{mode}/#{scenario}")
      end
    after
      Enum.each(Enum.reverse(started), &Application.stop/1)
      File.rm_rf!(root)
    end
  end

  defp run_case(git, root, mode, scenario) do
    dir = Path.join(root, "#{mode}-#{scenario}")
    repo = Path.join(dir, "repo")
    source = Path.join(dir, "vendor-source")
    init_repo(git, repo)
    init_repo(git, source)
    File.write!(Path.join(repo, "tracked.txt"), "committed\n")
    File.write!(Path.join(source, "version.txt"), "original\n")
    commit_all(git, source, "Original local dependency")
    old_pin = git!(git, source, ["rev-parse", "HEAD"])

    git!(git, repo, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "--",
      source,
      "vendor"
    ])

    commit_all(git, repo, "Initial tree with local submodule")
    repo = git!(git, repo, ["rev-parse", "--show-toplevel"])
    File.write!(Path.join(source, "version.txt"), "updated\n")
    commit_all(git, source, "Updated local dependency")
    pin = git!(git, source, ["rev-parse", "HEAD"])
    git!(git, repo, ["config", "diff.ignoreSubmodules", "all"])
    git!(git, repo, ["config", "submodule.vendor.ignore", "all"])

    # Committed `.gitmodules` filters make git add skip a moved submodule HEAD.
    if scenario == "initialized" do
      git!(git, repo, ["config", "--file", ".gitmodules", "submodule.vendor.ignore", "all"])
      commit_all(git, repo, "Ignore local dependency checkout")
    end

    File.write!(Path.join(repo, "tracked.txt"), "parent staged\n")
    git!(git, repo, ["add", "tracked.txt"])
    File.write!(Path.join(repo, "tracked.txt"), "parent unstaged\n")
    File.write!(Path.join(repo, "private.txt"), "parent untracked\n")
    parent = snapshot(git, repo)
    parent_vendor = snapshot(git, Path.join(repo, "vendor"))

    command =
      case scenario do
        "staged" ->
          "git update-index --cacheinfo 160000,#{pin},vendor"

        "committed" ->
          "git update-index --cacheinfo 160000,#{pin},vendor" <>
            " && git -c core.hooksPath=/dev/null commit -qm 'Child gitlink pin'"

        "initialized" ->
          "git -c protocol.file.allow=always submodule update --init -q -- vendor" <>
            " && git -C vendor checkout -q --detach #{pin}" <>
            " && printf 'ordinary child file\\n' > child.txt"

        "empty" ->
          nil

        "files" ->
          "printf 'ordinary child file\\n' > child.txt"
      end

    result =
      TaskTool.execute(
        unique_id(),
        %{
          "prompt" => "Perform the local Git fixture operation",
          "worktree" => true,
          "merge" => mode,
          "tool_policy" => %{"allow" => "all"},
          "async" => false,
          "auto_followup" => false
        },
        nil,
        nil,
        repo,
        parent_session: unique_id(),
        model: "openai-codex:gpt-6.1-sol",
        settings_manager: %SettingsManager{},
        stream_fn: provider(command)
      )

    check!(is_map(result), "Public task failed: #{inspect(result)}")
    merge = result.details.merge
    worktree = result.details.worktree_path
    branch = result.details.branch
    check!(merge.mode == mode, "Wrong merge mode")
    {:ok, record, _events} = TaskStore.get(result.details.task_id)
    check!(record.workspace.merge == merge, "Stored/public merge outcomes differ")

    case scenario do
      state when state in ["staged", "committed"] ->
        check!(merge.status == "error", "Gitlink work was classified #{merge.status}")
        check!(File.dir?(worktree), "Recoverable task checkout was removed")
        check!(branch_exists?(git, repo, branch), "Recoverable task branch was removed")

        check!(
          git!(git, worktree, ["symbolic-ref", "--short", "HEAD"]) == branch,
          "Task branch checkout changed"
        )

        check!(git!(git, worktree, ["rev-parse", ":vendor"]) == pin, "Task index pin was lost")

        check!(
          !File.exists?(Path.join(worktree, "vendor/.git")),
          "Fixture must remain uninitialized"
        )

        if state == "committed" do
          check!(
            git!(git, repo, ["rev-parse", "#{branch}:vendor"]) == pin,
            "Child gitlink commit is not recoverable"
          )

          check!(
            git!(git, worktree, ["diff", "--cached", "--name-only"]) == "",
            "Committed fixture unexpectedly has staged changes"
          )
        else
          check!(
            git!(git, worktree, ["rev-parse", "HEAD:vendor"]) == old_pin,
            "Finalization unexpectedly committed the staged fixture"
          )

          check!(
            git!(git, worktree, [
              "diff",
              "--cached",
              "--name-only",
              "--ignore-submodules=none",
              "HEAD"
            ]) == "vendor",
            "Staged pointer-only change is not recoverable"
          )
        end

      "initialized" ->
        check!(merge.status == "error", "Submodule checkout was classified #{merge.status}")
        check!(File.dir?(worktree), "Recoverable task checkout was removed")
        check!(branch_exists?(git, repo, branch), "Recoverable task branch was removed")

        check!(
          git!(git, worktree, ["symbolic-ref", "--short", "HEAD"]) == branch,
          "Task branch checkout changed"
        )

        check!(
          git!(git, Path.join(worktree, "vendor"), ["rev-parse", "HEAD"]) == pin,
          "Task submodule checkout was lost"
        )

        check!(git!(git, worktree, ["rev-parse", ":vendor"]) == old_pin, "Task index changed")

        check!(
          git!(git, repo, ["rev-parse", "#{branch}:vendor"]) == old_pin and
            git!(git, repo, ["ls-tree", "--name-only", branch, "--", "child.txt"]) == "",
          "Finalization committed part of the task"
        )

        check!(
          File.read!(Path.join(worktree, "child.txt")) == "ordinary child file\n",
          "Task file was lost"
        )

        check!(!File.exists?(Path.join(repo, "child.txt")), "Partial task reached the parent")

      "empty" ->
        check!(merge.status == "no_changes", "Genuinely empty task was not recognized")
        check!(!File.exists?(worktree), "Empty task checkout was not cleaned")
        check!(!branch_exists?(git, repo, branch), "Empty task branch was not cleaned")

      "files" ->
        check!(!File.exists?(worktree), "Ordinary file task checkout was not cleaned")

        if mode == "patch" do
          check!(merge.status == "applied", "Ordinary patch was not applied")

          check!(
            File.read!(Path.join(repo, "child.txt")) == "ordinary child file\n",
            "Ordinary child file did not reach the parent"
          )

          check!(!branch_exists?(git, repo, branch), "Applied patch branch was not cleaned")
        else
          check!(merge.status == "committed", "Ordinary branch task was not committed")

          check!(
            git!(git, repo, ["show", "#{branch}:child.txt"]) == "ordinary child file",
            "Ordinary child file is not on the review branch"
          )

          check!(!File.exists?(Path.join(repo, "child.txt")), "Branch mode mutated parent files")
        end
    end

    # Patch mode may add its ordinary output file, but cannot touch the user's
    # preexisting HEAD, index, working files or initialized submodule checkout.
    after_parent = snapshot(git, repo)
    check!(after_parent.head == parent.head, "Parent HEAD changed")
    check!(after_parent.index == parent.index, "Parent index changed")
    check!(after_parent.staged == parent.staged, "Parent staged changes changed")
    check!(after_parent.unstaged == parent.unstaged, "Parent unstaged changes changed")

    unless mode == "patch" && scenario == "files" do
      check!(after_parent.status == parent.status, "Parent checkout status changed")
    end

    check!(snapshot(git, Path.join(repo, "vendor")) == parent_vendor, "Parent submodule changed")

    check!(
      File.read!(Path.join(repo, "tracked.txt")) == "parent unstaged\n",
      "Parent WIP changed"
    )

    check!(
      File.read!(Path.join(repo, "private.txt")) == "parent untracked\n",
      "Parent private file changed"
    )

    check!(
      File.read!(Path.join(repo, "vendor/version.txt")) == "original\n",
      "Parent submodule file changed"
    )
  end

  defp provider(command) do
    fn model, context, _options ->
      answered? = Enum.any?(context.messages, &(Map.get(&1, :role) == :tool_result))
      tool? = is_binary(command) && !answered?

      content =
        if tool? do
          [%ToolCall{id: unique_id(), name: "bash", arguments: %{"command" => command}}]
        else
          [%TextContent{text: "Local Git fixture operation finished."}]
        end

      message = %AssistantMessage{
        content: content,
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: %Usage{},
        stop_reason: if(tool?, do: :tool_use, else: :stop),
        timestamp: System.system_time(:millisecond)
      }

      {:ok, stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(stream, {:start, message})
        LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
        LemonAi.EventStream.complete(stream, message)
      end)

      {:ok, stream}
    end
  end

  defp init_repo(git, repo) do
    File.mkdir_p!(repo)
    git!(git, repo, ["init", "-q", "-b", "main"])
    git!(git, repo, ["config", "user.name", "Task Worktree Smoke"])
    git!(git, repo, ["config", "user.email", "worktree-smoke@example.invalid"])
  end

  defp commit_all(git, repo, message) do
    git!(git, repo, ["add", "."])
    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", message])
  end

  defp snapshot(git, repo) do
    %{
      head: git!(git, repo, ["rev-parse", "HEAD"]),
      index: git!(git, repo, ["write-tree"]),
      staged:
        git!(git, repo, [
          "diff",
          "--cached",
          "--binary",
          "--no-ext-diff",
          "--ignore-submodules=none",
          "HEAD"
        ]),
      unstaged:
        git!(git, repo, ["diff", "--binary", "--no-ext-diff", "--ignore-submodules=none"]),
      status: git!(git, repo, ["status", "--porcelain=v1", "-z", "--ignore-submodules=none"])
    }
  end

  defp branch_exists?(git, repo, branch) do
    {_output, status} =
      System.cmd(git, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], cd: repo)

    status == 0
  end

  defp git!(git, repo, args) do
    {output, status} = System.cmd(git, args, cd: repo, stderr_to_stdout: true)
    check!(status == 0, "Git failed #{inspect(args)}: #{output}")
    String.trim_trailing(output, "\n")
  end

  defp check!(true, _message), do: :ok
  defp check!(false, message), do: raise(message)
  defp unique_id, do: "worktree-smoke-#{System.unique_integer([:positive, :monotonic])}"
end

LemonScripts.TaskWorktreesSmoke.main()
