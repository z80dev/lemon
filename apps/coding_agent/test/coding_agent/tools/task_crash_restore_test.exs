Code.require_file("../../support/task_worktree_case.ex", __DIR__)

defmodule CodingAgent.Tools.TaskCrashRestoreTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, TaskStore, TaskStoreServer}
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.{Control, Restore, Wait}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.ToolCall
  import CodingAgent.Tools.Task.WorktreeCase, only: [git!: 3, checkout_snapshot: 2]

  @moduletag :tmp_dir
  @provider :task_crash_restore_test
  @owner_key {__MODULE__, :owner}

  defmodule Provider do
    def stream(_model, context, _opts) do
      owner = :persistent_term.get({CodingAgent.Tools.TaskCrashRestoreTest, :owner})
      send(owner, {:provider_entered, self(), context})

      receive do
        {:respond, message} ->
          {:ok, stream} = LemonAi.EventStream.start_link()
          LemonAi.EventStream.push(stream, {:start, message})
          LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
          LemonAi.EventStream.complete(stream, message)
          {:ok, stream}
      end
    end
  end

  setup do
    cwd = Path.join(System.tmp_dir!(), "task_crash_restore_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    running = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :coding_agent))
    if running, do: :ok = Application.stop(:coding_agent)
    keys = [:task_store_path, :run_graph_path]
    saved_env = Map.new(keys, &{&1, Application.fetch_env(:coding_agent, &1)})
    config_file = LemonCore.Config.Modular.global_path()
    saved_config = File.read(config_file)
    previous_provider = LemonAi.ProviderRegistry.get(@provider)
    :persistent_term.put(@owner_key, self())
    LemonAi.ProviderRegistry.register(@provider, Provider)

    Application.put_env(:coding_agent, :task_store_path, Path.join(cwd, "tasks.dets"))
    Application.put_env(:coding_agent, :run_graph_path, Path.join(cwd, "runs.dets"))
    set_flag(config_file, true)
    {:ok, _} = Application.ensure_all_started(:coding_agent)

    on_exit(fn ->
      Application.stop(:coding_agent)

      Enum.each(saved_env, fn
        {key, {:ok, value}} -> Application.put_env(:coding_agent, key, value)
        {key, :error} -> Application.delete_env(:coding_agent, key)
      end)

      case saved_config do
        {:ok, data} -> File.write!(config_file, data)
        {:error, :enoent} -> File.rm(config_file)
      end

      LemonCore.ConfigCache.clear()
      :persistent_term.erase(@owner_key)

      case previous_provider do
        {:ok, module} -> LemonAi.ProviderRegistry.register(@provider, module)
        _ -> LemonAi.ProviderRegistry.unregister(@provider)
      end

      File.rm_rf!(cwd)

      if running, do: Application.ensure_all_started(:coding_agent)
    end)

    %{cwd: cwd, config_file: config_file}
  end

  test "brutal application restart restores one turn and await finds the original ID", %{cwd: cwd} do
    {parent, opts} = parent(cwd)
    task_id = launch(cwd, opts)
    assert_receive {:provider_entered, provider, _context}, 5_000

    send(provider, {:respond, unknown_effect_message()})
    assert_receive {:effect_entered, _effect_worker}, 5_000
    {:ok, before} = TaskStore.get_record(task_id)
    assert before.status == :running
    assert before.launch_descriptor.start_opts[:session_file] == before.session_file
    assert_data(before.launch_descriptor)

    assert {:ok, [%{id: "unknown-call", name: "crash_effect"}]} =
             CodingAgent.ToolIntent.unknown_calls(before.session_file)

    brutal_restart()
    assert {:ok, %{status: :interrupted}} = TaskStore.get_record(task_id)
    refute Process.alive?(parent)
    refute_receive {:provider_entered, _, _}

    {_resumed, resumed_opts} = parent(cwd)

    1..4
    |> Task.async_stream(fn _ ->
      Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
    end)
    |> Enum.each(fn result -> assert result == {:ok, :ok} end)

    assert_receive {:provider_entered, continuation, context}, 5_000
    prompt = inspect(List.last(context.messages))
    assert prompt =~ "unknown-call"
    assert prompt =~ "crash_effect"
    assert prompt =~ "Do not automatically repeat"
    refute prompt =~ "private-argument"
    refute_receive {:effect_entered, _}
    refute_receive {:provider_entered, _, _}

    assert {:ok, restored} = TaskStore.get_record(task_id)
    assert restored.run_id == before.run_id
    assert restored.parent_run_id == before.parent_run_id
    assert restored.parent_session_id == resumed_opts[:parent_session]
    assert restored.owner == Control.owner(resumed_opts)
    assert restored.restart_attempt == 1

    waiter = Task.async(fn -> Wait.execute(%{"task_ids" => [task_id]}, nil, resumed_opts) end)
    send(continuation, {:respond, Mocks.assistant_message("reconciled child result")})
    assert %AgentToolResult{details: %{tasks: [result]}} = Task.await(waiter, 5_000)
    assert result.task_id == task_id
    assert result.status == "completed"
    assert result.output == "reconciled child result"
    refute_receive {:effect_entered, _}
  end

  test "a store-only restart cannot redrive a surviving child worker", %{cwd: cwd} do
    {_parent, opts} = parent(cwd)
    task_id = launch(cwd, opts)
    assert_receive {:provider_entered, provider, _}, 5_000
    :ok = Supervisor.terminate_child(CodingAgent.Supervisor, TaskStoreServer)
    {:ok, _} = Supervisor.restart_child(CodingAgent.Supervisor, TaskStoreServer)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, opts)
    assert {:ok, record} = TaskStore.get_record(task_id)
    assert Map.get(record, :restart_attempt, 0) == 0
    refute_receive {:provider_entered, _, _}
    send(provider, {:respond, Mocks.assistant_message("original worker survived")})
  end

  test "executor restores children before the parent can await their original IDs", %{cwd: cwd} do
    {original_parent, opts} = parent(cwd, [])
    :ok = Session.save(original_parent)
    task_id = launch(cwd, opts)
    assert_receive {:provider_entered, _provider, _}, 5_000
    brutal_restart()

    request = %LemonGateway.ExecutionRequest{
      run_id: opts[:run_id],
      session_key: "agent:default:task-crash-parent:#{opts[:run_id]}",
      cwd: cwd,
      prompt: "Await the original child.",
      images: [],
      resume: %LemonCore.ResumeToken{engine: "lemon", value: opts[:parent_session]},
      meta: %{
        crash_resume: true,
        restart_continuation: true,
        restart_attempt: 1,
        model: Mocks.mock_model(api: @provider),
        thinking_level: :off,
        project_memory_capture: false
      }
    }

    run_ref = make_ref()

    {:ok, runner} =
      CodingAgent.Executor.SessionRunner.start_link(
        request: request,
        sink_pid: self(),
        run_ref: run_ref
      )

    assert_receive {:provider_entered, first, first_context}, 5_000
    assert_receive {:provider_entered, second, second_context}, 5_000

    {child_provider, parent_provider} =
      if inspect(List.last(first_context.messages)) =~ "daemon crashed" do
        assert inspect(List.last(second_context.messages)) =~ "Await the original child"
        {first, second}
      else
        assert inspect(List.last(first_context.messages)) =~ "Await the original child"
        assert inspect(List.last(second_context.messages)) =~ "daemon crashed"
        {second, first}
      end

    assert {:ok, %{status: :running, restart_attempt: 1} = record} = TaskStore.get_record(task_id)
    %{session: resumed_parent} = :sys.get_state(runner)
    parent_state = Session.get_state(resumed_parent)
    assert record.owner == Control.owner(parent_state.tool_opts)

    send(
      parent_provider,
      {:respond,
       %{
         Mocks.assistant_message("")
         | content: [
             %ToolCall{id: "await-original", name: "wait", arguments: %{"task_ids" => [task_id]}}
           ],
           stop_reason: :tool_use
       }}
    )

    send(child_provider, {:respond, Mocks.assistant_message("original child answer")})
    assert_receive {:provider_entered, parent_after_wait, context}, 5_000
    assert inspect(context.messages) =~ task_id
    assert inspect(context.messages) =~ "original child answer"

    send(
      parent_after_wait,
      {:respond, Mocks.assistant_message("Parent received the original result.")}
    )

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed, ok: true}}, 5_000
    GenServer.stop(runner, :normal)
  end

  test "unresumed, graceful-only, unrelated and aborted parents never redrive", %{cwd: cwd} do
    {_parent, opts} = parent(cwd)
    task_id = launch(cwd, opts)
    assert_receive {:provider_entered, _provider, _}, 5_000
    brutal_restart()
    assert {:ok, %{status: :interrupted}} = TaskStore.get_record(task_id)
    {_parent, resumed_opts} = parent(cwd)

    :ok = Restore.restore_parent(opts[:run_id], %{}, resumed_opts)
    :ok = Restore.restore_parent(opts[:run_id], %{restart_continuation: true}, resumed_opts)
    :ok = Restore.restore_parent("unrelated-run", %{crash_resume: true}, resumed_opts)
    signal = AbortSignal.new()
    AbortSignal.abort(signal)

    :ok =
      Restore.restore_parent(
        opts[:run_id],
        %{crash_resume: true},
        Keyword.put(resumed_opts, :parent_signal, signal)
      )

    refute_receive {:provider_entered, _, _}
    assert {:ok, record} = TaskStore.get_record(task_id)
    assert record.status == :interrupted
    assert Map.get(record, :restart_attempt, 0) == 0

    assert {:error, :not_interrupted} =
             TaskStoreServer.claim_restore(task_id, "unrelated-run", Control.owner(resumed_opts))
  end

  test "a durable parent abort blocks recovery before its signal arrives", %{cwd: cwd} do
    {_parent, opts} = parent(cwd)
    task_id = launch(cwd, opts)
    assert_receive {:provider_entered, _provider, _}, 5_000
    brutal_restart()
    {_parent, resumed_opts} = parent(cwd)
    run_id = opts[:run_id]
    signal = AbortSignal.new()
    refute AbortSignal.aborted?(signal)

    on_exit(fn -> LemonCore.Store.delete(:router_abort_tombstones, run_id) end)

    assert :ok =
             LemonCore.Store.put(
               LemonCore.Store,
               :router_abort_tombstones,
               run_id,
               %{state: "aborted", reason_code: "user_requested"},
               durable: true
             )

    assert :ok =
             Restore.restore_parent(
               run_id,
               %{crash_resume: true},
               Keyword.put(resumed_opts, :parent_signal, signal)
             )

    assert {:ok, record} = TaskStore.get_record(task_id)
    assert record.status == :interrupted
    assert Map.get(record, :restart_attempt, 0) == 0
    refute AbortSignal.aborted?(signal)
    refute_receive {:provider_entered, _, _}
  end

  test "flag off durably abandons children even when a later boot enables it", %{
    cwd: cwd,
    config_file: config_file
  } do
    {_parent, opts} = parent(cwd)
    task_id = launch(cwd, opts)
    assert_receive {:provider_entered, _provider, _}, 5_000
    set_flag(config_file, false)
    brutal_restart()
    assert {:ok, %{status: :lost, error: :lost_on_restart}} = TaskStore.get_record(task_id)
    {_parent, resumed_opts} = parent(cwd)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
    refute_receive {:provider_entered, _, _}

    set_flag(config_file, true)
    brutal_restart()
    {_parent, resumed_opts} = parent(cwd)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
    assert {:ok, %{status: :lost}} = TaskStore.get_record(task_id)
    refute_receive {:provider_entered, _, _}
  end

  test "repeated brutal crashes consume at most three durable continuation attempts", %{cwd: cwd} do
    {_parent, opts} = parent(cwd)
    task_id = launch(cwd, opts)
    assert_receive {:provider_entered, _provider, _}, 5_000

    for attempt <- 1..3 do
      brutal_restart()
      {_parent, resumed_opts} = parent(cwd)
      :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
      assert_receive {:provider_entered, _provider, _}, 5_000
      assert {:ok, %{status: :running, restart_attempt: ^attempt}} = TaskStore.get_record(task_id)
    end

    brutal_restart()
    {_parent, resumed_opts} = parent(cwd)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
    assert {:ok, %{status: :lost, restart_attempt: 3}} = TaskStore.get_record(task_id)
    refute_receive {:provider_entered, _, _}
  end

  test "terminal writers win before and after a restore claim, including another restart", %{
    cwd: cwd
  } do
    {_parent, opts} = parent(cwd)
    task_id = launch(cwd, opts)
    assert_receive {:provider_entered, _provider, _}, 5_000
    brutal_restart()
    {_parent, resumed_opts} = parent(cwd)
    :ok = TaskStore.cancel(task_id, :parent_aborted)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
    refute_receive {:provider_entered, _, _}
    assert {:ok, %{status: :cancelled, error: :parent_aborted}} = TaskStore.get_record(task_id)

    second = launch(cwd, resumed_opts)
    assert_receive {:provider_entered, _provider, _}, 5_000
    brutal_restart()
    {_parent, latest_opts} = parent(cwd)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, latest_opts)
    assert_receive {:provider_entered, provider, _}, 5_000

    winner = %AgentToolResult{
      content: [%LemonAi.Types.TextContent{text: "first terminal"}],
      details: %{}
    }

    :ok = TaskStore.finish(second, winner)
    :ok = TaskStore.fail(second, :late_failure)
    :ok = TaskStore.cancel(second, :late_cancel)
    send(provider, {:respond, Mocks.assistant_message("late provider result")})
    assert {:ok, %{status: :completed, result: ^winner}} = TaskStore.get_record(second)
    brutal_restart()
    assert {:ok, %{status: :completed, result: ^winner}} = TaskStore.get_record(second)
    assert {:ok, %{status: :cancelled, error: :parent_aborted}} = TaskStore.get_record(task_id)
  end

  test "worktree children resume in place without replaying creation, merge or cleanup", %{
    cwd: cwd
  } do
    for mode <- ["none", "patch", "branch"] do
      {git, repo} = repository!(cwd, mode)

      repo =
        if mode == "branch" do
          linked = Path.join(cwd, "linked-parent")
          git!(git, repo, ["worktree", "add", "-b", "linked-parent", linked])
          linked
        else
          repo
        end

      {_parent, opts} = parent(repo)
      task_id = launch(repo, opts, %{"worktree" => true, "merge" => mode})

      receive do
        {:provider_entered, _provider, _} ->
          :ok
      after
        5_000 ->
          flunk("Native worktree child did not start: #{inspect(TaskStore.get_record(task_id))}")
      end

      assert {:ok, original} = TaskStore.get_record(task_id)
      workspace = original.workspace
      assert original.launch_descriptor.start_opts[:cwd] == workspace.cwd
      assert_data(original.launch_descriptor)
      File.write!(Path.join(workspace.cwd, "tracked.txt"), "interrupted child changes\n")
      parent_before = checkout_snapshot(git, repo)
      child_before = checkout_snapshot(git, workspace.cwd)
      worktrees_before = git!(git, repo, ["worktree", "list", "--porcelain"])

      brutal_restart()
      {_parent, resumed_opts} = parent(repo)
      :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
      assert_receive {:provider_entered, provider, context}, 5_000
      assert inspect(List.last(context.messages)) =~ "original existing worktree"
      assert inspect(List.last(context.messages)) =~ "cleanup are not replayed"
      assert {:ok, restored} = TaskStore.get_record(task_id)
      assert restored.session_file == original.session_file
      assert restored.workspace.worktree_path == workspace.worktree_path
      assert restored.workspace.branch == workspace.branch
      session = Control.hub_state([task_id])[task_id].session
      assert Session.get_state(session).cwd == workspace.cwd

      waiter = Task.async(fn -> Wait.execute(%{"task_ids" => [task_id]}, nil, resumed_opts) end)
      send(provider, {:respond, Mocks.assistant_message("continued in original worktree")})
      assert %AgentToolResult{details: %{tasks: [result]}} = Task.await(waiter, 5_000)
      assert result.task_id == task_id
      assert result.status == "completed"
      assert result.worktree_path == workspace.worktree_path
      assert result.merge.mode == mode
      assert result.merge.status == "not_replayed"
      assert File.dir?(workspace.worktree_path)
      assert checkout_snapshot(git, repo) == parent_before
      assert checkout_snapshot(git, workspace.cwd) == child_before
      assert git!(git, repo, ["worktree", "list", "--porcelain"]) == worktrees_before
    end
  end

  test "a missing original worktree is not recreated by recovery", %{cwd: cwd} do
    {_git, repo} = repository!(cwd, "removed")
    {_parent, opts} = parent(repo)
    task_id = launch(repo, opts, %{"worktree" => true})
    assert_receive {:provider_entered, _provider, _}, 5_000
    {:ok, record} = TaskStore.get_record(task_id)
    brutal_restart()
    File.rm_rf!(record.workspace.worktree_path)
    {_parent, resumed_opts} = parent(repo)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)

    assert {:ok, %{status: :lost, error: :crash_restore_unavailable}} =
             TaskStore.get_record(task_id)

    refute File.exists?(record.workspace.worktree_path)
    refute_receive {:provider_entered, _, _}
  end

  test "native swarm leaves resume without replaying their coordinator or pending DAG nodes", %{
    cwd: cwd
  } do
    {_parent, opts} = parent(cwd)

    assert %AgentToolResult{details: %{task_id: coordinator_id, run_id: coordinator_run}} =
             TaskTool.execute(
               "swarm-launch",
               %{
                 "action" => "swarm",
                 "async" => true,
                 "auto_followup" => false,
                 "concurrency" => 2,
                 "tasks" => [
                   %{"name" => "a", "prompt" => "First native leaf"},
                   %{"name" => "b", "prompt" => "Second native leaf"},
                   %{"name" => "pending", "prompt" => "Never redrive", "depends_on" => ["a", "b"]}
                 ]
               },
               nil,
               nil,
               cwd,
               opts
             )

    assert_receive {:provider_entered, _first, _}, 5_000
    assert_receive {:provider_entered, _second, _}, 5_000

    children =
      TaskStore.list()
      |> Enum.filter(fn {_id, record} -> record[:parent_run_id] == coordinator_run end)

    assert length(children) == 2
    ids = Enum.map(children, &elem(&1, 0))

    for {_id, record} <- children do
      refute record.orchestration_worker
      assert record.status == :running
      assert Restore.resumable?(record.launch_descriptor)
    end

    brutal_restart()
    {_parent, resumed_opts} = parent(cwd)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
    assert_receive {:provider_entered, first, _}, 5_000
    assert_receive {:provider_entered, second, _}, 5_000

    assert {:ok, %{status: :lost, orchestration_worker: true}} =
             TaskStore.get_record(coordinator_id)

    send(first, {:respond, Mocks.assistant_message("resumed leaf")})
    send(second, {:respond, Mocks.assistant_message("resumed leaf")})

    for id <- ids do
      assert %AgentToolResult{details: %{tasks: [%{task_id: ^id, status: "completed"}]}} =
               Wait.execute(%{"task_ids" => [id]}, nil, resumed_opts)
    end

    assert {:ok, %{status: :lost}} = TaskStore.get_record(coordinator_id)
    refute Enum.any?(TaskStore.list(), fn {_id, record} -> record[:name] == "pending" end)
    refute_receive {:provider_entered, _, _}
  end

  test "a durably cancelled swarm coordinator never authorizes its native leaves", %{cwd: cwd} do
    {_parent, opts} = parent(cwd)

    assert %AgentToolResult{details: %{task_id: coordinator_id, run_id: coordinator_run}} =
             TaskTool.execute(
               "cancelled-swarm",
               %{
                 "action" => "swarm",
                 "async" => true,
                 "auto_followup" => false,
                 "tasks" => [%{"name" => "leaf", "prompt" => "Native leaf"}]
               },
               nil,
               nil,
               cwd,
               opts
             )

    assert_receive {:provider_entered, _provider, _}, 5_000

    [{leaf_id, _}] =
      Enum.filter(TaskStore.list(), fn {_id, record} ->
        record[:parent_run_id] == coordinator_run
      end)

    :ok = TaskStore.cancel(coordinator_id, :user_requested)
    brutal_restart()
    {_parent, resumed_opts} = parent(cwd)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
    assert {:ok, %{status: :cancelled}} = TaskStore.get_record(coordinator_id)
    assert {:ok, record} = TaskStore.get_record(leaf_id)
    assert record.status == :interrupted
    assert Map.get(record, :restart_attempt, 0) == 0
    refute_receive {:provider_entered, _, _}
  end

  test "unsupported launches and unreadable journals are lost without running effects", %{
    cwd: cwd
  } do
    {_parent, opts} = parent(cwd)
    owner = self()

    receipt =
      TaskTool.execute(
        "unsupported",
        %{"prompt" => "wait", "async" => true},
        nil,
        nil,
        cwd,
        Keyword.put(opts, :run_override, fn _, _ ->
          send(owner, :unsupported_entered)

          receive do
            :finish -> Mocks.assistant_message("unused")
          end
        end)
      )

    assert_receive :unsupported_entered, 5_000
    task_id = receipt.details.task_id
    readable = launch(cwd, opts)
    assert_receive {:provider_entered, _provider, _}, 5_000
    {:ok, record} = TaskStore.get_record(readable)
    brutal_restart()
    File.rm!(record.session_file)
    {_parent, resumed_opts} = parent(cwd)
    :ok = Restore.restore_parent(opts[:run_id], %{crash_resume: true}, resumed_opts)
    assert {:ok, %{status: :lost}} = TaskStore.get_record(task_id)

    assert {:ok, %{status: :lost, error: :crash_restore_unavailable}} =
             TaskStore.get_record(readable)

    refute_receive {:provider_entered, _, _}
    refute_receive :unsupported_entered
  end

  defp parent(cwd, tools \\ [effect_tool()]) do
    model = Mocks.mock_model(api: @provider)
    run_id = "parent-crash-run:" <> Path.basename(cwd)

    {:ok, session} =
      CodingAgent.start_session(
        cwd: cwd,
        run_id: run_id,
        model: model,
        extra_tools: tools,
        system_prompt: "Deterministic crash recovery fixture.",
        thinking_level: :off,
        project_memory_capture: false
      )

    session_id = Session.get_stats(session).session_id

    {session,
     [
       run_id: run_id,
       parent_session: session_id,
       session_id: session_id,
       session_pid: session,
       agent_id: Session.get_state(session).agent_id,
       model: model,
       thinking_level: :off,
       extra_tools: tools,
       tool_policy: %{allow: :all},
       settings_manager: %CodingAgent.SettingsManager{provider_routing: %{enabled: false}}
     ]}
  end

  defp launch(cwd, opts, params \\ %{}) do
    assert %AgentToolResult{details: %{task_id: id}} =
             TaskTool.execute(
               "launch",
               Map.merge(
                 %{
                   "prompt" => "Complete the child assignment.",
                   "async" => true,
                   "auto_followup" => false
                 },
                 params
               ),
               nil,
               nil,
               cwd,
               opts
             )

    id
  end

  defp repository!(cwd, name) do
    git = System.find_executable("git") || raise "Git is required for worktree recovery tests"
    repo = Path.join(cwd, "worktree-#{name}")
    File.mkdir_p!(repo)
    git!(git, repo, ["init", "-q", "-b", "main"])
    git!(git, repo, ["config", "user.name", "Crash Restore Test"])
    git!(git, repo, ["config", "user.email", "crash-restore@example.invalid"])
    File.write!(Path.join(repo, "tracked.txt"), "committed\n")
    git!(git, repo, ["add", "tracked.txt"])
    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Initial tree"])
    {git, git!(git, repo, ["rev-parse", "--show-toplevel"])}
  end

  defp effect_tool do
    owner = self()

    %AgentTool{
      name: "crash_effect",
      label: "Crash fixture effect",
      description: "A controlled effect that never returns before the crash.",
      parameters: %{"type" => "object", "properties" => %{}},
      effect: :external,
      execute: fn _, _, _, _ ->
        send(owner, {:effect_entered, self()})

        receive do
          :finish -> %AgentToolResult{content: [], details: %{}}
        end
      end
    }
  end

  defp unknown_effect_message do
    %{
      Mocks.assistant_message("")
      | content: [
          %ToolCall{
            id: "unknown-call",
            name: "crash_effect",
            arguments: %{"secret" => "private-argument"}
          }
        ],
        stop_reason: :tool_use
    }
  end

  # Freeze cancellation and durable writers before killing the entire app tree.
  # This is not Application.stop/1: no terminate callback can turn the cut-off
  # task into a normal cancellation. DETS files remain in place for the restart.
  defp brutal_restart do
    supervisor = Process.whereis(CodingAgent.Supervisor)
    descendants = supervised_processes(supervisor)
    :ok = :sys.suspend(supervisor)
    :ok = :sys.suspend(Process.whereis(Control))
    :ok = :sys.suspend(Process.whereis(TaskStoreServer))
    refs = Enum.map([supervisor | descendants], &{Process.monitor(&1), &1})
    Enum.each(descendants, &Process.exit(&1, :kill))
    Process.exit(supervisor, :kill)

    Enum.each(refs, fn {ref, pid} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end)

    Application.stop(:coding_agent)
    {:ok, _} = Application.ensure_all_started(:coding_agent)
  end

  defp supervised_processes(supervisor) do
    Enum.flat_map(Supervisor.which_children(supervisor), fn
      {_, pid, :supervisor, _} when is_pid(pid) -> [pid | supervised_processes(pid)]
      {_, pid, _, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end

  defp set_flag(path, enabled) do
    File.mkdir_p!(Path.dirname(path))
    value = if enabled, do: "on", else: "off"
    File.write!(path, "[features]\ncrash_resume = \"#{value}\"\nsession_search = \"off\"\n")
    LemonCore.ConfigCache.clear()
  end

  defp assert_data(term) when is_map(term), do: Enum.each(Map.to_list(term), &assert_data/1)
  defp assert_data(term) when is_list(term), do: Enum.each(term, &assert_data/1)

  defp assert_data(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.each(&assert_data/1)

  defp assert_data(term) do
    refute is_pid(term) or is_port(term) or is_function(term) or is_reference(term)
  end
end
