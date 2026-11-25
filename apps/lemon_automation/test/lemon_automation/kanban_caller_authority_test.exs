defmodule LemonAutomation.KanbanCallerAuthorityTest do
  @moduledoc """
  Regression coverage for kanban dispatch escalation (audit T12-2, T05-4).

  Work created, edited or dispatched through the model-facing `kanban` tool
  runs through the real dispatcher, run worker and Git worktree preparation and
  never holds more authority than the sessions that shaped it. Routing identity
  (principal, session, run, workspace) comes from trusted session context.
  """

  use ExUnit.Case, async: false
  alias LemonAutomation.{KanbanAuthority, KanbanStore}
  alias LemonAutomation.{KanbanDispatcher, KanbanRunWorker}
  alias LemonCore.{ExecutionContext, ToolPolicy}
  alias LemonAutomation.Tools.Kanban

  defmodule Router do
    @moduledoc false

    def submit(params) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:router_submit, params})
      {:ok, params.run_id}
    end

    def abort_run(run_id, reason) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:router_abort, run_id, reason})
      :ok
    end
  end

  defmodule Waiter do
    @moduledoc false

    def wait_already_subscribed(run_id, _timeout_ms, _opts) do
      send(:persistent_term.get({Router, :test_pid}), {:waiter_started, self(), run_id})

      receive do
        {:finish, ^run_id, result} -> result
      after
        5_000 -> :timeout
      end
    end

    def wait(run_id, timeout_ms, opts), do: wait_already_subscribed(run_id, timeout_ms, opts)
  end

  @delegation ~w(kanban goal cron agent_message peer agent task nodes)

  setup do
    :persistent_term.put({Router, :test_pid}, self())
    base = Path.join(System.tmp_dir!(), "kanban-authority-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    on_exit(fn ->
      :persistent_term.erase({Router, :test_pid})

      KanbanStore.list_boards(limit: 1_000)
      |> Enum.each(fn board ->
        try do
          KanbanDispatcher.stop_board(board.id)
        catch
          :exit, _ -> :ok
        end

        KanbanStore.clear_board(board.id)
      end)

      File.rm_rf!(base)
    end)

    %{base: base, repo: repo!(base, "repo")}
  end

  defp session(agent_id, session_key, extra \\ []) do
    Keyword.merge(
      [
        agent_id: agent_id,
        session_key: session_key,
        run_id: "run_caller_#{System.unique_integer([:positive])}"
      ],
      extra
    )
  end

  defp kanban(params, cwd, opts), do: Kanban.execute("call", params, nil, nil, cwd, opts)

  defp worker_opts(extra \\ []),
    do: Keyword.merge([router_mod: Router, waiter_mod: Waiter, timeout_ms: 5_000], extra)

  # Operator-style start (web/channel): no caller policy is supplied.
  defp start_dispatcher(board_id, extra \\ []) do
    name = :"kanban-authority-#{System.unique_integer([:positive])}"
    start_supervised!({KanbanDispatcher, name: name, worker_mod: KanbanRunWorker}, id: name)

    result =
      KanbanDispatcher.start_board(
        board_id,
        Keyword.merge([name: name, interval_ms: 10, worker_opts: worker_opts()], extra)
      )

    {name, result}
  end

  defp create_card(cwd, opts, extra \\ %{}) do
    assert %{details: %{board: board}} =
             kanban(%{"action" => "board_create", "name" => "Authority"}, cwd, opts)

    assert %{details: %{task: task}} =
             kanban(
               Map.merge(
                 %{"action" => "task_create", "board_id" => board.id, "title" => "Work"},
                 extra
               ),
               cwd,
               opts
             )

    {board, task}
  end

  defp finish_run do
    assert_receive {:waiter_started, waiter, run_id}, 5_000
    send(waiter, {:finish, run_id, {:ok, "done"}})
  end

  test "recorded caller policies confine real worktree dispatch", %{repo: repo} do
    {:ok, context} =
      ExecutionContext.new(
        run_id: "run_context",
        agent_id: "agent_a",
        cwd: repo,
        tool_policy: ToolPolicy.custom(deny: ["write"])
      )

    cases = [
      {"struct deny", [tool_policy: ToolPolicy.custom(deny: ["bash"])],
       fn p -> refute ToolPolicy.allowed?(p, "bash") end},
      {"json deny and approval",
       [tool_policy: %{"deny" => ["bash"], "approvals" => %{"write" => "always"}}],
       fn p ->
         refute ToolPolicy.allowed?(p, "bash")
         assert ToolPolicy.requires_approval?(p, "write", %{}, :write)
       end},
      {"read_only profile", [tool_policy: ToolPolicy.from_profile(:read_only)],
       fn p ->
         for tool <- ~w(bash write edit patch eval agent task),
             do: refute(ToolPolicy.allowed?(p, tool), tool)
       end},
      {"json profile", [tool_policy: %{"profile" => "read_only"}],
       fn p -> refute ToolPolicy.allowed?(p, "write") end},
      {"no_external", [tool_policy: ToolPolicy.from_profile(:no_external)],
       fn p ->
         for tool <- ~w(webfetch websearch browser_navigate),
             do: refute(ToolPolicy.allowed?(p, tool), tool)
       end},
      {"approval mode", [tool_policy: ToolPolicy.custom(approval_mode: :ask)],
       fn p -> assert ToolPolicy.requires_approval?(p, "bash", %{"command" => "ls"}, :exec) end},
      {"json policy with struct execution context",
       [tool_policy: %{"deny" => ["bash"]}, execution_context: context],
       fn p ->
         refute ToolPolicy.allowed?(p, "bash")
         refute ToolPolicy.allowed?(p, "write")
       end},
      {"unrestricted caller", [], fn p -> assert ToolPolicy.allowed?(p, "bash") end}
    ]

    for {label, policy_opts, check} <- cases do
      opts =
        session(
          "agent_a",
          "agent:agent_a:main:#{System.unique_integer([:positive])}",
          policy_opts
        )

      {board, task} = create_card(repo, opts)
      {_name, {:ok, _}} = start_dispatcher(board.id)

      assert_receive {:router_submit, params}, 5_000
      assert params.meta.kanban_task_id == task.id, label
      check.(params.tool_policy)

      for tool <- @delegation,
          do: refute(ToolPolicy.allowed?(params.tool_policy, tool), "#{label}: #{tool}")

      assert {:ok, _} = ToolPolicy.normalize(params.tool_policy), label
      assert params.agent_id == "agent_a"
      # Executed in a controller-created worktree outside the caller's root.
      {:ok, expected_cwd} = LemonAutomation.KanbanWorktree.path_for(task)
      assert params.cwd == expected_cwd, label
      refute String.starts_with?(params.cwd, repo <> "/"), label
      assert LemonAutomation.KanbanGitWorkflow.clean_path?(params.cwd)
      assert {:ok, params.meta.cwd_identity} == KanbanAuthority.directory_identity(params.cwd)
      # File-mutation tools are confined to that worktree.
      assert params.meta.mutation_root == params.cwd, label
      assert params.meta.kanban_worktree_root == repo
      finish_run()
    end
  end

  test "a kanban worker cannot reach any delegation surface", %{repo: repo} do
    {board, _task} = create_card(repo, session("agent_a", "agent:agent_a:main"))
    {_name, {:ok, _}} = start_dispatcher(board.id)
    assert_receive {:router_submit, params}, 5_000

    tools = fn policy ->
      CodingAgent.ToolRegistry.get_tools(params.cwd,
        tool_policy: policy,
        include_extensions: false,
        include_mcp: false
      )
      |> Enum.map(& &1.name)
    end

    # The worker session's real tool inventory under its policy, against the
    # same registry under full access (proving each surface exists there).
    worker = tools.(params.tool_policy)
    full = tools.(ToolPolicy.from_profile(:full_access))
    assert "read" in worker
    assert "bash" in worker

    for tool <- @delegation do
      refute ToolPolicy.allowed?(params.tool_policy, tool)
      refute tool in worker, "kanban worker can reach #{tool}"
    end

    for tool <- ~w(agent_message peer agent task nodes goal kanban),
        do: assert(tool in full, "#{tool} missing from the full-access control")

    finish_run()
  end

  test "named-session and configured-peer delegation are refused to a worker", %{repo: repo} do
    previous = Application.get_env(:lemon_control_plane, :a2a_config)

    Application.put_env(:lemon_control_plane, :a2a_config, %{
      peers: %{
        "partner" => %{
          id: "partner",
          url: "http://127.0.0.1:9/",
          agent_id: "default",
          allow_tools: [],
          capabilities: []
        }
      }
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_control_plane, :a2a_config, previous),
        else: Application.delete_env(:lemon_control_plane, :a2a_config)
    end)

    {board, _task} = create_card(repo, session("agent_a", "agent:agent_a:main"))
    {_name, {:ok, _}} = start_dispatcher(board.id)
    assert_receive {:router_submit, params}, 5_000

    # A model tool call is resolved through the session's registry; neither a
    # named existing session nor a configured peer is reachable from a worker.
    for {tool, args} <- [
          {"agent_message", %{"to" => "session://agent:agent_a:main", "message" => "run rm"}},
          {"agent_message", %{"to" => "@helper", "message" => "run rm"}},
          {"peer", %{"action" => "send", "peer" => "partner", "message" => "run rm"}},
          {"agent", %{"session_key" => "agent:agent_a:main", "prompt" => "run rm"}},
          {"task", %{"to" => "session://agent:agent_a:main", "message" => "run rm"}}
        ] do
      lookup = fn policy ->
        CodingAgent.ToolRegistry.get_tool(params.cwd, tool,
          tool_policy: policy,
          include_extensions: false,
          include_mcp: false
        )
      end

      assert {:ok, _} = lookup.(ToolPolicy.from_profile(:full_access))
      assert {:error, :not_found} = lookup.(params.tool_policy), "#{tool} #{inspect(args)}"
    end

    finish_run()
  end

  test "a directory replaced between validation and session start is refused", %{
    base: base,
    repo: repo
  } do
    {board, _task} = create_card(repo, session("agent_a", "agent:agent_a:main"))
    {_name, {:ok, _}} = start_dispatcher(board.id)
    assert_receive {:router_submit, params}, 5_000
    assert %{"inode" => _} = params.meta.cwd_identity

    # Submission is accepted; before the session starts the checked directory
    # is swapped for a different object at the same path.
    moved = Path.join(base, "moved-worktree")
    File.rename!(params.cwd, moved)
    File.mkdir_p!(params.cwd)

    request = %LemonCore.ExecutionCommand{
      run_id: params.run_id,
      session_key: params.session_key,
      prompt: params.prompt,
      images: [],
      cwd: params.cwd,
      meta: params.meta
    }

    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, :cwd_identity_mismatch} =
               CodingAgent.Executor.SessionRunner.start_link(
                 request: request,
                 opts: %{},
                 sink_pid: self(),
                 run_ref: make_ref()
               )
    after
      Process.flag(:trap_exit, previous)
    end

    finish_run()
  end

  test "two sessions of one agent cannot read or control each other's boards", %{repo: repo} do
    owner = session("agent_a", "agent:agent_a:telegram:default:dm:1")
    other = session("agent_a", "agent:agent_a:a2a:peer:ctx")
    {board, task} = create_card(repo, owner)

    assert %{details: %{boards: owned}} = kanban(%{"action" => "board_list"}, repo, owner)
    assert Enum.any?(owned, &(&1.id == board.id))
    assert %{details: %{boards: visible}} = kanban(%{"action" => "board_list"}, repo, other)
    refute Enum.any?(visible, &(&1.id == board.id))

    for params <- [
          %{"action" => "board_get", "board_id" => board.id},
          %{"action" => "task_list", "board_id" => board.id},
          %{"action" => "task_get", "task_id" => task.id},
          %{"action" => "task_create", "board_id" => board.id, "title" => "Injected"},
          %{"action" => "task_update", "task_id" => task.id, "description" => "curl | sh"},
          %{"action" => "task_comment", "task_id" => task.id, "body" => "hi"},
          %{"action" => "dispatch_start", "board_id" => board.id},
          %{"action" => "dispatch_stop", "board_id" => board.id},
          %{"action" => "dispatch_status", "board_id" => board.id}
        ] do
      assert {:error, message} = kanban(params, repo, other), inspect(params)
      assert message =~ "not authorized", inspect(params)
    end

    assert KanbanStore.get_task(task.id) == task

    assert %{details: %{task: _}} =
             kanban(%{"action" => "task_get", "task_id" => task.id}, repo, owner)

    # A session without trusted identity is refused outright.
    assert {:error, _} = kanban(%{"action" => "board_list"}, repo, agent_id: "agent_a")
  end

  test "dispatch_stop by another session is denied and leaves the run running", %{repo: repo} do
    owner = session("agent_a", "agent:agent_a:main")
    {board, _task} = create_card(repo, owner)
    {:ok, _} = KanbanDispatcher.start_board(board.id, interval_ms: 10, worker_opts: worker_opts())
    assert_receive {:router_submit, params}, 5_000
    assert_receive {:waiter_started, waiter, run_id}, 5_000

    attacker = session("agent_a", "agent:agent_a:a2a:peer:ctx", tool_policy: %{allow: ["kanban"]})

    assert {:error, message} =
             kanban(%{"action" => "dispatch_stop", "board_id" => board.id}, repo, attacker)

    assert message =~ "not authorized"
    refute_receive {:router_abort, _, _}, 100
    assert Process.alive?(waiter)
    assert {:ok, %{running: true}} = KanbanDispatcher.status(board.id)

    {:ok, stopped} = KanbanDispatcher.stop_board(board.id)
    assert [%{run_id: ^run_id, result: :ok}] = stopped.aborts
    assert_receive {:router_abort, ^run_id, :kanban_board_stop}
    assert params.run_id == run_id
  end

  test "an operator share grant lets another session control the board", %{repo: repo} do
    owner = session("agent_a", "agent:agent_a:main")
    other = session("agent_a", "agent:agent_a:main:sub:helper")
    {board, _task} = create_card(repo, owner)
    {:ok, status} = KanbanDispatcher.status(board.id)

    assert {:ok, _} =
             KanbanDispatcher.share_board(board.id, "agent:agent_a:main:sub:helper",
               expected_revision: status.control_revision
             )

    assert %{details: %{board: _}} =
             kanban(%{"action" => "board_get", "board_id" => board.id}, repo, other)
  end

  test "a dispatch starter's restriction survives stop and an operator restart", %{repo: repo} do
    owner = session("agent_a", "agent:agent_a:main")
    {board, task} = create_card(repo, owner, %{"depends_on" => ["task_not_yet"]})
    {:ok, status} = KanbanDispatcher.status(board.id)

    {:ok, _} =
      KanbanDispatcher.share_board(board.id, "agent:agent_a:a2a:peer:ctx",
        expected_revision: status.control_revision
      )

    starter =
      session("agent_a", "agent:agent_a:a2a:peer:ctx",
        tool_policy: %{allow: ["read", "write", "edit", "kanban"]}
      )

    assert %{details: %{dispatch: %{status: "running"}}} =
             kanban(%{"action" => "dispatch_start", "board_id" => board.id}, repo, starter)

    assert %{details: %{dispatch: %{status: "stopped"}}} =
             kanban(%{"action" => "dispatch_stop", "board_id" => board.id}, repo, starter)

    assert %{details: %{task: _}} =
             kanban(
               %{"action" => "task_update", "task_id" => task.id, "depends_on" => []},
               repo,
               owner
             )

    # Restarted by an operator (web) with no caller policy.
    {_name, {:ok, _}} = start_dispatcher(board.id)
    assert_receive {:router_submit, params}, 5_000
    refute ToolPolicy.allowed?(params.tool_policy, "bash")
    assert ToolPolicy.allowed?(params.tool_policy, "write")
    finish_run()
  end

  test "the model cannot choose a card's session, run, owner, profile or another agent",
       %{repo: repo} do
    opts = session("agent_a", "agent:agent_a:main")

    assert {:error, _} =
             kanban(
               %{"action" => "board_create", "name" => "Spoofed", "owner" => "victim"},
               repo,
               opts
             )

    %{details: %{board: board}} =
      kanban(%{"action" => "board_create", "name" => "Routing"}, repo, opts)

    for {key, value} <- [
          {"session_key", "agent:victim:main"},
          {"run_id", "run_victim"},
          {"worker_profile", "admin"},
          {"assignee", "victim"}
        ] do
      assert {:error, _} =
               kanban(
                 %{
                   "action" => "task_create",
                   "board_id" => board.id,
                   "title" => "Hijack",
                   key => value
                 },
                 repo,
                 opts
               ),
             key
    end

    %{details: %{task: task}} =
      kanban(%{"action" => "task_create", "board_id" => board.id, "title" => "Legit"}, repo, opts)

    assert task.assignee == "agent_a"

    for {key, value} <- [{"session_key", "agent:victim:main"}, {"run_id", "run_victim"}] do
      assert {:error, _} =
               kanban(
                 %{"action" => "task_update", "task_id" => task.id, key => value},
                 repo,
                 opts
               )
    end

    {_name, {:ok, _}} = start_dispatcher(board.id)
    assert_receive {:router_submit, params}, 5_000
    assert String.starts_with?(params.session_key, "agent:agent_a:main:sub:kanban_")
    finish_run()
  end

  test "board workspace is canonical and cannot escape the caller cwd", %{base: base, repo: repo} do
    opts = session("agent_a", "agent:agent_a:main")
    outside = Path.join(base, "outside")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(repo, "sub"))
    File.ln_s!(outside, Path.join(repo, "link"))

    for workspace <- [
          "/",
          outside,
          "../",
          Path.join(repo, "../outside"),
          "link",
          "link/deeper",
          "missing"
        ] do
      assert {:error, message} =
               kanban(
                 %{"action" => "board_create", "name" => "Escape", "workspace" => workspace},
                 repo,
                 opts
               ),
             "workspace #{inspect(workspace)} escaped"

      assert message =~ "workspace"
    end

    refute Enum.any?(KanbanStore.list_boards(limit: 1_000), &(&1.name == "Escape"))

    # The default workspace is canonicalized too (a symlinked cwd resolves).
    alias_link = Path.join(base, "repo-alias")
    File.ln_s!(repo, alias_link)

    %{details: %{board: aliased}} =
      kanban(%{"action" => "board_create", "name" => "Alias"}, alias_link, opts)

    assert aliased.workspace == repo

    %{details: %{board: inside}} =
      kanban(%{"action" => "board_create", "name" => "Inside", "workspace" => "sub"}, repo, opts)

    assert inside.workspace == Path.join(repo, "sub")
  end

  test "a workspace replaced by a symlink before dispatch is refused", %{base: base, repo: repo} do
    opts = session("agent_a", "agent:agent_a:main")
    sub = Path.join(repo, "sub")
    File.mkdir_p!(sub)

    %{details: %{board: board}} =
      kanban(%{"action" => "board_create", "name" => "Swap", "workspace" => "sub"}, repo, opts)

    %{details: %{task: task}} =
      kanban(%{"action" => "task_create", "board_id" => board.id, "title" => "Work"}, repo, opts)

    outside = repo!(base, "elsewhere")
    File.rm_rf!(sub)
    File.ln_s!(outside, sub)

    {_name, {:ok, _}} = start_dispatcher(board.id)
    refute_receive {:router_submit, _}, 300
    failed = await_card(task.id, &is_map(&1.meta["lastFailure"]))
    assert failed.meta["lastFailure"]["reason"] == "workspace_changed"
    refute File.exists?(Path.join([outside, ".worktrees"]))
  end

  test "a subdirectory workspace never promotes to its parent repository", %{repo: repo} do
    sub = Path.join(repo, "pkg")
    File.mkdir_p!(sub)
    {board, task} = create_card(sub, session("agent_a", "agent:agent_a:main"))
    {_name, {:ok, _}} = start_dispatcher(board.id)
    refute_receive {:router_submit, _}, 300
    failed = await_card(task.id, &is_map(&1.meta["lastFailure"]))
    assert failed.meta["lastFailure"]["reason"] == "worktree_outside_authorized_root"
    refute File.exists?(Path.join(repo, ".worktrees"))
  end

  test "work without recorded authority is quarantined", %{repo: repo} do
    {:ok, board} = KanbanStore.create_board("Legacy", owner: "agent_a", workspace: repo)
    {:ok, task} = KanbanStore.create_task(board.id, "Legacy instructions")

    {_name, result} = start_dispatcher(board.id)
    assert {:error, :kanban_authority_missing} = result
    assert {:error, :kanban_authority_missing} = KanbanRunWorker.run(task, worker_opts())
    refute_receive {:router_submit, _}, 100

    # Model-visible tools cannot see or adopt it either.
    opts = session("agent_a", "agent:agent_a:main")
    assert {:error, _} = kanban(%{"action" => "board_get", "board_id" => board.id}, repo, opts)
  end

  test "only a trusted, card-bound dispatcher session is reused", %{repo: repo} do
    opts = session("agent_a", "agent:agent_a:main")
    {board, task} = create_card(repo, opts)
    stored = KanbanStore.get_task(task.id)
    legacy = "agent:agent_a:main:sub:kanban_attacker"

    :ok =
      LemonCore.Store.put(:kanban_tasks, task.id, %{
        stored
        | session_key: legacy,
          meta: Map.put(stored.meta, "kanbanRun", %{"status" => "failed", "sessionKey" => legacy})
      })

    {_name, {:ok, _}} = start_dispatcher(board.id)
    assert_receive {:router_submit, params}, 5_000
    refute params.session_key == legacy
    assert String.starts_with?(params.session_key, "agent:agent_a:main:sub:kanban_")
    finish_run()
  end

  test "a rewritten card cannot make stop_board abort an unrelated run", %{repo: repo} do
    {board, task} = create_card(repo, session("agent_a", "agent:agent_a:main"))
    {name, {:ok, _}} = start_dispatcher(board.id)
    assert_receive {:router_submit, params}, 5_000
    assert_receive {:waiter_started, _waiter, run_id}, 5_000
    leased = KanbanStore.get_task(task.id)
    routing = &Map.take(&1, [:run_id, :session_key, :assignee])

    assert {:error, _} =
             KanbanStore.update_task(task.id, %{
               run_id: "run_victim",
               session_key: "agent:victim:main"
             })

    # Lease renewals may tick between reads; routing identity must not change.
    current = KanbanStore.get_task(task.id)
    assert routing.(current) == routing.(leased)
    assert current.meta["kanbanRun"] == leased.meta["kanbanRun"]
    :ok = LemonCore.Store.put(:kanban_tasks, task.id, %{current | run_id: "run_victim"})

    {:ok, stopped} = KanbanDispatcher.stop_board(board.id, name: name)
    assert [%{run_id: ^run_id, result: :ok}] = stopped.aborts
    assert_receive {:router_abort, ^run_id, :kanban_board_stop}
    refute_receive {:router_abort, "run_victim", _}, 100
    assert params.run_id == run_id
  end

  defp await_card(id, predicate, attempts \\ 300) do
    task = KanbanStore.get_task(id)

    cond do
      predicate.(task) -> task
      attempts > 0 -> Process.sleep(10) && await_card(id, predicate, attempts - 1)
      true -> flunk("card did not reach expected state: #{inspect(task, limit: 20)}")
    end
  end

  defp repo!(base, name) do
    root = Path.join(base, name)
    File.mkdir_p!(root)
    git!(root, ["init", "-b", "main"])
    git!(root, ["config", "user.name", "Kanban Test"])
    git!(root, ["config", "user.email", "kanban@example.invalid"])
    File.write!(Path.join(root, ".gitignore"), ".worktrees/\n")
    File.write!(Path.join(root, "README.md"), "# test\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", "init"])
    git!(root, ["rev-parse", "--show-toplevel"])
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
