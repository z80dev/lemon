defmodule LemonAutomation.KanbanCodingWorkflowTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.KanbanStore
  alias LemonAutomation.{KanbanDispatcher, KanbanGitWorkflow, KanbanRunWorker}

  defmodule Router do
    def submit(params) do
      %{state: state, test_pid: test_pid} = :persistent_term.get(__MODULE__)
      phase = if params.meta[:kanban_phase] == "review", do: :review, else: :coding

      output =
        Agent.get_and_update(state, fn data ->
          if phase == :coding do
            count = data.codes + 1
            File.write!(Path.join(params.cwd, "file.txt"), "coding pass #{count}\n")
            {"Implemented coding pass #{count}", %{data | codes: count}}
          else
            [approved | rest] = data.reviews

            output =
              Jason.encode!(%{
                approved: approved,
                findings: if(approved, do: "No blockers", else: "Fix the blocking defect")
              })

            {output, %{data | reviews: rest}}
          end
        end)

      Agent.update(
        state,
        &put_in(&1.runs[params.run_id], %{params: params, phase: phase, output: output})
      )

      send(test_pid, {:submitted, phase, params})
      {:ok, params.run_id}
    end

    def abort_run(run_id, _) do
      %{state: state} = :persistent_term.get(__MODULE__)
      record = Agent.get(state, &Map.fetch!(&1.runs, run_id))

      LemonCore.RunStore.finalize(run_id, %{
        session_key: record.params.session_key,
        completed: %{ok: false, error: "cancelled"}
      })

      :ok
    end
  end

  defmodule Waiter do
    def wait_already_subscribed(run_id, _, _) do
      %{state: state, test_pid: test_pid} = :persistent_term.get(Router)
      {record, block?} = Agent.get(state, &{Map.fetch!(&1.runs, run_id), &1.block_review})

      if record.phase == :review and block? do
        send(test_pid, {:review_waiting, self(), run_id})

        receive do
          :finish_review -> :ok
        after
          10_000 -> exit(:review_fixture_timeout)
        end
      end

      LemonCore.RunStore.finalize(run_id, %{
        session_key: record.params.session_key,
        completed: %{ok: true, answer: record.output}
      })

      {:ok, record.output}
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: directory} do
    git!(directory, ["init", "-b", "main"])
    root = git!(directory, ["rev-parse", "--show-toplevel"])
    git!(root, ["config", "user.name", "Workflow Test"])
    git!(root, ["config", "user.email", "workflow@example.invalid"])
    File.write!(Path.join(root, ".gitignore"), ".worktrees/\nremote.git/\n")
    File.write!(Path.join(root, "file.txt"), "initial\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "fixture"])
    base = git!(root, ["rev-parse", "HEAD"])
    remote = Path.join(root, "remote.git")
    git!(root, ["init", "--bare", remote])
    git!(root, ["remote", "add", "origin", remote])

    state =
      start_supervised!(
        {Agent, fn -> %{codes: 0, reviews: [true], runs: %{}, block_review: false, pushes: 0} end}
      )

    :persistent_term.put(Router, %{state: state, test_pid: self()})
    name = :"workflow_dispatcher_#{System.unique_integer([:positive])}"
    manager = start_supervised!({KanbanDispatcher, name: name, worker_mod: KanbanRunWorker})
    on_exit(fn -> :persistent_term.erase(Router) end)
    %{root: root, remote: remote, base: base, state: state, name: name, manager: manager}
  end

  test "review gates completion and commits locally without pushing", context do
    Agent.update(context.state, &%{&1 | block_review: true})
    {board, card} = create(context, %{})
    assert {:error, :review_required} = KanbanStore.update_task(card.id, %{status: "done"})

    assert {:error, :review_required} =
             KanbanStore.create_task(board.id, "Bypass", status: "done")

    start(context, board)
    assert_receive {:submitted, :coding, coding}, 5_000
    assert_receive {:submitted, :review, review}, 5_000
    assert_receive {:review_waiting, waiter, _run_id}, 5_000
    assert review.meta.system_prompt =~ "Independent test reviewer"
    assert review.tool_policy.allow == ["read"]
    assert review.prompt =~ "+coding pass 1"
    assert review.meta.parent_run_id == coding.run_id
    # Both the coding run and the reviewer may only change files in the worktree.
    assert coding.meta.mutation_root == coding.cwd
    assert review.meta.mutation_root == review.cwd
    leased = KanbanStore.get_task(card.id)

    assert {:error, :review_required} =
             KanbanStore.complete_leased_task(card.id, leased.meta["kanbanLease"]["id"])

    refute leased.status == "done"
    send(waiter, :finish_review)
    done = await_card(card.id, &(&1.status == "done"))
    workflow = done.meta["codingWorkflow"]
    assert workflow["review"]["approved"]
    assert workflow["reviewRunId"] == review.run_id
    assert workflow["phase"] == "completed"
    assert workflow["published"] == false
    assert git!(workflow["cwd"], ["rev-parse", "HEAD"]) == workflow["commitSha"]
    assert git!(workflow["cwd"], ["status", "--porcelain"]) == ""
    assert git!(context.root, ["rev-parse", "HEAD"]) == context.base
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "a blocking review gets one corrective pass before commit", context do
    Agent.update(context.state, &%{&1 | reviews: [false, true]})
    {board, card} = create(context, %{})
    start(context, board)
    done = await_card(card.id, &(&1.status == "done"))
    assert done.meta["codingWorkflow"]["round"] == 2
    assert Agent.get(context.state, & &1.codes) == 2
    assert_receive {:submitted, :coding, _}
    assert_receive {:submitted, :coding, revision}
    assert revision.prompt =~ "Fix the blocking defect"
    assert git!(done.meta["codingWorkflow"]["cwd"], ["show", "HEAD:file.txt"]) == "coding pass 2"
  end

  test "repeated rejection never commits or marks the card done", context do
    Agent.update(context.state, &%{&1 | reviews: [false, false]})
    {board, card} = create(context, %{})
    start(context, board)
    failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))
    assert failed.meta["lastFailure"]["reason"] == "review_rejected"
    refute failed.status == "done"
    assert failed.meta["codingWorkflow"]["round"] == 2
    assert git!(failed.meta["codingWorkflow"]["cwd"], ["rev-parse", "HEAD"]) == context.base
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "lost review waiter resumes the original approved run without another editor", context do
    Agent.update(context.state, &%{&1 | block_review: true})
    {board, card} = create(context, %{})
    start(context, board)
    assert_receive {:review_waiting, worker, run_id}, 5_000
    Process.exit(worker, :kill)
    await_card(card.id, &(get_in(&1.meta, ["kanbanRun", "status"]) == "outcome_unknown"))
    record = Agent.get(context.state, &Map.fetch!(&1.runs, run_id))

    LemonCore.RunStore.finalize(run_id, %{
      session_key: record.params.session_key,
      completed: %{ok: true, answer: record.output}
    })

    done = await_card(card.id, &(&1.status == "done"))
    assert done.meta["codingWorkflow"]["reviewRunId"] == run_id
    assert Agent.get(context.state, & &1.codes) == 1
    assert map_size(Agent.get(context.state, & &1.runs)) == 2
  end

  test "stop during review cannot commit or publish after the late result", context do
    Agent.update(context.state, &%{&1 | block_review: true})
    {board, card} = create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})
    start(context, board)
    assert_receive {:review_waiting, _worker, _run_id}, 5_000
    assert {:ok, _} = KanbanDispatcher.stop_board(board.id, name: context.name)
    stopped = await_card(card.id, &is_map(&1.meta["lastFailure"]))
    assert stopped.meta["codingWorkflow"]["cancelRequested"]
    assert stopped.meta["lastFailure"]["reason"] == "cancelled"
    assert git!(stopped.meta["codingWorkflow"]["cwd"], ["rev-parse", "HEAD"]) == context.base
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "an uncertain successful push is reconciled, never sent twice", context do
    {board, card} = create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})
    grant_publication(context, board)

    # Every command runs in the workflow's sanitized environment (it carries
    # the commit identity); only the push's outcome is made uncertain.
    runner = fn program, args, opts ->
      result = KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))

      if "push" in args do
        Agent.update(context.state, &%{&1 | pushes: &1.pushes + 1})
        assert {:ok, _} = result
        {:error, :command_timeout}
      else
        result
      end
    end

    start(context, board, git_opts: [runner: runner])
    done = await_card(card.id, &(&1.status == "done"))
    workflow = done.meta["codingWorkflow"]
    assert workflow["published"]
    assert Agent.get(context.state, & &1.pushes) == 1

    assert git!(context.remote, ["rev-parse", "refs/heads/" <> workflow["branch"]]) ==
             workflow["commitSha"]
  end

  test "a model-selected publish setting needs a creator whose policy permits it", context do
    publish = %{"publish" => %{"mode" => "branch", "remote" => "origin"}}

    for policy <- [
          LemonCore.ToolPolicy.from_profile(:no_external),
          LemonCore.ToolPolicy.custom(approvals: %{"bash" => :always}),
          %{"deny" => ["bash"]},
          LemonCore.ToolPolicy.custom(allowed_commands: ["git status"]),
          LemonCore.ToolPolicy.custom(blocked_commands: ["git push"]),
          LemonCore.ToolPolicy.custom(approvals: %{"webfetch" => :always})
        ] do
      assert {:error, message} =
               kanban(
                 %{"action" => "board_create", "name" => "Publish", "coding_workflow" => publish},
                 context.root,
                 session(tool_policy: policy)
               ),
             inspect(policy)

      assert message =~ "publish"
    end
  end

  test "publication needs a separate operator grant bound to the exact settings", context do
    {board, card} = create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})
    {:ok, status} = KanbanDispatcher.status(board.id, name: context.name)

    # The operator previewed one destination; the remote's push URL then
    # changed before confirmation.
    assert {:ok, %{digest: previewed, destinations: %{"push" => [remote]}}} =
             KanbanDispatcher.publication_preview(board.id)

    assert remote == context.remote
    elsewhere = Path.join(context.root, "elsewhere.git")
    git!(context.root, ["init", "--bare", elsewhere])
    git!(context.root, ["config", "remote.origin.pushurl", elsewhere])

    assert {:error, :stale} =
             KanbanDispatcher.grant_publication(board.id,
               name: context.name,
               expected_revision: status.control_revision,
               publish_digest: previewed
             )

    # An unrestricted creator alone cannot publish.
    start(context, board)
    failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))
    assert failed.meta["lastFailure"]["reason"] == "publication_not_authorized"
    assert is_binary(failed.meta["codingWorkflow"]["commitSha"])
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
    assert git!(elsewhere, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "publication goes only to the granted destination, whatever the remote says later",
       context do
    elsewhere = Path.join(context.root, "elsewhere.git")
    git!(context.root, ["init", "--bare", elsewhere])

    for after_plan? <- [false, true] do
      {board, card} =
        create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})

      System.cmd("git", ["-C", context.root, "config", "--unset-all", "remote.origin.pushurl"])
      grant_publication(context, board)

      runner =
        if after_plan? do
          # After the plan was built: redirect just before the push runs.
          fn program, args, opts ->
            if "push" in args,
              do: git!(context.root, ["config", "remote.origin.pushurl", elsewhere])

            KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
          end
        else
          # After the grant: redirect before the card even starts.
          git!(context.root, ["config", "remote.origin.pushurl", elsewhere])
          nil
        end

      git_opts = if runner, do: [runner: runner], else: []
      Agent.update(context.state, &%{&1 | reviews: [true]})
      start(context, board, git_opts: git_opts)
      done = await_card(card.id, &(&1.status == "done"))
      workflow = done.meta["codingWorkflow"]
      assert workflow["published"]

      assert git!(context.remote, ["rev-parse", "refs/heads/" <> workflow["branch"]]) ==
               workflow["commitSha"]

      assert git!(elsewhere, ["for-each-ref", "--format=%(refname)"]) == ""
      KanbanDispatcher.stop_board(board.id, name: context.name)
    end
  end

  test "granted publication still honours the card's commands and approval floors", context do
    for policy <- [
          LemonCore.ToolPolicy.from_profile(:no_external),
          LemonCore.ToolPolicy.custom(blocked_commands: ["git push"]),
          LemonCore.ToolPolicy.custom(allowed_commands: ["git commit-tree", "git update-ref"]),
          LemonCore.ToolPolicy.custom(blocked_commands: ["git ls-remote"]),
          LemonCore.ToolPolicy.custom(approvals: %{"webfetch" => :always})
        ] do
      {board, card} =
        create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})

      grant_publication(context, board)
      restricted_edit(context, board, card, policy)
      Agent.update(context.state, &%{&1 | reviews: [true]})
      start(context, board)
      failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))
      assert failed.meta["lastFailure"]["reason"] == "publication_not_authorized", inspect(policy)
      assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
      KanbanDispatcher.stop_board(board.id, name: context.name)
    end
  end

  test "controller commits honour the card's command restrictions", context do
    {board, card} = create(context, %{})

    restricted_edit(
      context,
      board,
      card,
      LemonCore.ToolPolicy.custom(blocked_commands: ["git update-ref"])
    )

    start(context, board)
    failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))
    assert failed.meta["lastFailure"]["reason"] == "commit_not_authorized"
    assert git!(failed.meta["codingWorkflow"]["cwd"], ["rev-parse", "HEAD"]) == context.base
  end

  test "publication follows the card's recorded no_external restriction", context do
    {board, card} = create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})
    grant_publication(context, board)
    restricted_edit(context, board, card, LemonCore.ToolPolicy.from_profile(:no_external))
    start(context, board)
    failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))
    assert failed.meta["lastFailure"]["reason"] == "publication_not_authorized"
    refute failed.status == "done"
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "controller commands are authorized with every argument", context do
    branch = %{"mode" => "branch", "remote" => "origin"}

    pr = %{
      "mode" => "pull_request",
      "remote" => "origin",
      "repository" => "owner/repo",
      "base" => "main"
    }

    for {config, blocked, reason} <- [
          {%{}, "-m Fix the fixture", "commit_not_authorized"},
          {%{"publish" => branch}, "git ls-remote", "publication_not_authorized"},
          {%{"publish" => branch}, "--no-follow-tags", "publication_not_authorized"},
          {%{"publish" => pr}, "--base main", "publication_not_authorized"},
          {%{"publish" => pr}, "--state all", "publication_not_authorized"}
        ] do
      Agent.update(context.state, &Map.merge(&1, %{reviews: [true], network: []}))
      {board, card} = create(context, config)
      if config != %{}, do: grant_publication(context, board)
      policy = LemonCore.ToolPolicy.custom(blocked_commands: [blocked])
      restricted_edit(context, board, card, policy)
      start(context, board, git_opts: [runner: network_runner(context)])
      failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))
      assert failed.meta["lastFailure"]["reason"] == reason, blocked
      assert Agent.get(context.state, & &1.network) == [], blocked
      assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
      KanbanDispatcher.stop_board(board.id, name: context.name)
    end
  end

  test "publication recovery runs nothing the current authority does not allow", context do
    assert_recovery_refused(context, false)
  end

  test "cancellation reconciliation runs nothing the current authority does not allow",
       context do
    assert_recovery_refused(context, true)
  end

  # A dispatched push becomes ambiguous; the board is then narrowed to
  # no_external. Neither the scheduled reconciliation nor a stop-and-restart
  # (cancellation reconciliation) may run any network command afterwards.
  defp assert_recovery_refused(context, stop?) do
    Agent.update(context.state, &Map.put(&1, :network, []))
    {board, card} = create(context, %{"publish" => %{"mode" => "branch", "remote" => "origin"}})
    grant_publication(context, board)
    start(context, board, git_opts: [runner: network_runner(context)])

    await_card(card.id, fn task ->
      get_in(task.meta, ["codingWorkflow", "phase"]) == "publish_pending" and
        is_integer(get_in(task.meta, ["codingWorkflow", "reconcileAfterMs"]))
    end)

    assert Enum.any?(Agent.get(context.state, & &1.network), &("push" in &1))

    assert {:ok, _} =
             KanbanStore.restrict_authority(
               board.id,
               LemonCore.ToolPolicy.from_profile(:no_external)
             )

    Agent.update(context.state, &%{&1 | network: []})

    if stop? do
      assert {:ok, _} = KanbanDispatcher.stop_board(board.id, name: context.name)
      start(context, board, git_opts: [runner: network_runner(context)])
    end

    failed = await_card(card.id, &is_map(&1.meta["lastFailure"]), 2_000)
    assert failed.meta["lastFailure"]["reason"] == "publication_not_authorized"
    if stop?, do: assert(failed.meta["codingWorkflow"]["cancelRequested"])
    assert Agent.get(context.state, & &1.network) == []
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  test "a deny-bash board's repository configuration runs nothing in the controller",
       context do
    marker = Path.join(Path.dirname(context.root), "marker-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(marker) end)
    script = Path.join(Path.dirname(context.root), "evil-#{System.unique_integer([:positive])}")
    File.write!(script, "#!/bin/sh\necho \"$0 $*\" >> '#{marker}'\ncat\n")
    File.chmod!(script, 0o755)
    File.write!(Path.join(context.root, ".gitattributes"), "* filter=evil diff=evil\n")
    git!(context.root, ["add", ".gitattributes"])
    git!(context.root, ["commit", "-m", "attributes"])

    for hook <- ~w(post-checkout pre-commit post-commit reference-transaction post-index-change),
        do: File.cp!(script, Path.join([context.root, ".git", "hooks", hook]))

    for {key, value} <- [
          {"filter.evil.clean", script},
          {"filter.evil.smudge", script},
          {"filter.evil.required", "true"},
          {"diff.evil.textconv", script},
          {"core.fsmonitor", script}
        ],
        do: git!(context.root, ["config", key, value])

    {board, card} = create(context, %{}, tool_policy: %{"deny" => ["bash"]})
    start(context, board)
    failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))

    # Prepared, coded, staged and reviewed; the commit is refused (no bash).
    assert failed.meta["lastFailure"]["reason"] == "commit_not_authorized"
    assert get_in(failed.meta, ["codingWorkflow", "review", "approved"])
    refute File.exists?(marker)
  end

  # Real sandboxed Git, except network commands: those are recorded, and a
  # push reports a timeout without reaching the remote.
  defp network_runner(context) do
    fn program, args, opts ->
      if program == "gh" or Enum.any?(args, &(&1 in ["push", "ls-remote"])) do
        Agent.update(
          context.state,
          &Map.update(&1, :network, [args], fn seen -> [args | seen] end)
        )
      end

      if program == "git" and "push" in args,
        do: {:error, :command_timeout},
        else: KanbanGitWorkflow.command(program, args, Keyword.delete(opts, :runner))
    end
  end

  # The operator web/control path: revision-, settings- and destination-bound.
  defp grant_publication(context, board) do
    {:ok, status} = KanbanDispatcher.status(board.id, name: context.name)
    assert {:ok, %{digest: digest}} = KanbanDispatcher.publication_preview(board.id)

    assert {:ok, _} =
             KanbanDispatcher.grant_publication(board.id,
               name: context.name,
               expected_revision: status.control_revision,
               publish_digest: digest
             )
  end

  # A shared session with a narrower policy edits the card, recording its policy.
  defp restricted_edit(context, board, card, policy) do
    {:ok, status} = KanbanDispatcher.status(board.id, name: context.name)
    restricted_key = "agent:default:main:sub:restricted"

    {:ok, _} =
      KanbanDispatcher.share_board(board.id, restricted_key,
        name: context.name,
        expected_revision: status.control_revision
      )

    assert %{details: %{task: _}} =
             kanban(
               %{"action" => "task_update", "task_id" => card.id, "priority" => "high"},
               context.root,
               session(session_key: restricted_key, tool_policy: policy)
             )
  end

  test "operator reauthorization never grants publication", context do
    {:ok, board} =
      KanbanStore.create_board("Legacy publish",
        workspace: context.root,
        meta: %{"codingWorkflow" => %{"publish" => %{"mode" => "branch", "remote" => "origin"}}}
      )

    on_exit(fn -> KanbanStore.clear_board(board.id) end)
    {:ok, card} = KanbanStore.create_task(board.id, "Legacy publish card")
    {:ok, status} = KanbanDispatcher.status(board.id, name: context.name)

    assert {:ok, _} =
             KanbanDispatcher.reauthorize_board(board.id,
               name: context.name,
               expected_revision: status.control_revision
             )

    start(context, board)
    failed = await_card(card.id, &is_map(&1.meta["lastFailure"]))
    assert failed.meta["lastFailure"]["reason"] == "publication_not_authorized"
    assert git!(context.remote, ["for-each-ref", "--format=%(refname)"]) == ""
  end

  defp session(extra \\ []) do
    Keyword.merge([agent_id: "default", session_key: "agent:default:main"], extra)
  end

  defp kanban(params, cwd, opts),
    do: LemonSkills.Tools.Kanban.execute("call", params, nil, nil, cwd, opts)

  defp create(context, config, session_opts \\ []) do
    %{details: %{board: board}} =
      kanban(
        %{"action" => "board_create", "name" => "Reviewed work", "coding_workflow" => config},
        context.root,
        session(session_opts)
      )

    %{details: %{task: task}} =
      kanban(
        %{"action" => "task_create", "board_id" => board.id, "title" => "Fix the fixture"},
        context.root,
        session(session_opts)
      )

    on_exit(fn -> KanbanStore.clear_board(board.id) end)
    {board, task}
  end

  defp start(context, board, extra \\ []) do
    resolver = fn _, "reviewer" ->
      {:ok,
       %{
         prompt: "Independent test reviewer",
         model: nil,
         role: nil,
         tool_policy: %{allow: ["read", "bash"]}
       }}
    end

    # Trusted controller options: the local bare test remote uses `file`.
    git_opts = Keyword.merge([allowed_protocols: ["file"]], Keyword.get(extra, :git_opts, []))

    opts =
      [router_mod: Router, waiter_mod: Waiter, reviewer_resolver: resolver]
      |> Keyword.merge(extra)
      |> Keyword.put(:git_opts, git_opts)

    assert {:ok, _} =
             KanbanDispatcher.start_board(board.id,
               name: context.name,
               interval_ms: 10,
               worker_opts: opts
             )
  end

  defp await_card(id, predicate, attempts \\ 1_000) do
    task = KanbanStore.get_task(id)

    cond do
      predicate.(task) ->
        task

      attempts > 0 ->
        Process.sleep(10)
        await_card(id, predicate, attempts - 1)

      true ->
        flunk("card did not reach expected state: #{inspect(task, limit: 20)}")
    end
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
