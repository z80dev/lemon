defmodule LemonAutomation.Tools.CronTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.Tools.Cron

  defmodule AbortRouter do
    def abort_run(_id, _reason), do: :ok
  end

  defmodule SilentSubmitter do
    def submit(_job, _run, _opts), do: {:ok, "[SILENT]"}
  end

  setup do
    previous_router = Application.get_env(:lemon_automation, :cron_router_mod)
    Application.put_env(:lemon_automation, :cron_router_mod, AbortRouter)
    {:ok, _} = Application.ensure_all_started(:lemon_automation)
    clear_cron_data()

    on_exit(fn ->
      if previous_router,
        do: Application.put_env(:lemon_automation, :cron_router_mod, previous_router),
        else: Application.delete_env(:lemon_automation, :cron_router_mod)

      clear_cron_data()
    end)

    :ok
  end

  test "status and doctor expose restoration pending even without a durable pause" do
    alias LemonAutomation.{CronManager, CronStore}
    alias LemonAutomation.Doctor.Checks.Cron, as: CronCheck

    :ok = CronStore.clear_global_pause()
    original = :sys.get_state(CronManager).restoration_pending
    on_exit(fn -> :sys.replace_state(CronManager, &%{&1 | restoration_pending: original}) end)
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))

    for pending <- [true, false] do
      :sys.replace_state(CronManager, &%{&1 | restoration_pending: pending})
      status = call_tool(tool, %{"action" => "status"}).details
      assert status["paused"] == false
      assert status["restorationPending"] == pending
      check = Enum.find(CronCheck.run([]), &(&1.name == "automation.cron_paused"))

      if pending do
        assert check.status == :warn
        assert check.message =~ "restoration is pending"
        assert check.remediation =~ "store"
      else
        assert check == nil
      end
    end
  end

  test "list exposes persisted outcomes and failing filter; status counts failing jobs" do
    alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))

    result =
      call_tool(tool, %{
        "action" => "add",
        "name" => "fail-filter",
        "schedule" => "0 0 1 1 *",
        "prompt" => "hello",
        "enabled" => false,
        "deliverTo" => "none"
      })

    id = result.details["id"]
    run = id |> CronRun.new(:manual) |> CronRun.start(nil)
    CronStore.put_run(run)
    send(CronManager, {:run_complete, run.id, {:error, "run_failed"}})
    [job] = CronManager.list()
    assert CronJob.failure_streak(job) == 1
    failing = call_tool(tool, %{"action" => "list", "failing" => true})

    assert [%{"id" => ^id, "failureStreak" => 1, "lastStatus" => "failed"}] =
             failing.details["jobs"]

    status = call_tool(tool, %{"action" => "status"})
    assert status.details["failingJobs"] == 1

    run = id |> CronRun.new(:manual) |> CronRun.start(nil)
    CronStore.put_run(run)
    send(CronManager, {:run_complete, run.id, {:ok, "[SILENT]"}})
    assert call_tool(tool, %{"action" => "list", "failing" => true}).details["jobs"] == []
  end

  test "add, list, update, pause, resume, abort, and remove actions operate on Lemon internal cron" do
    session_key = LemonCore.SessionKey.main("default")
    tool = Cron.tool(".", session_key: session_key, agent_id: "default")

    add_result =
      call_tool(tool, %{
        "action" => "add",
        "name" => "Tool test job",
        "schedule" => "every 5 minutes",
        "prompt" => "say hello",
        "maxRetries" => 1,
        "retryBackoffMs" => 1_000
      })

    assert %{"id" => job_id, "name" => "Tool test job"} = add_result.details
    assert add_result.details["schedule"] == "*/5 * * * *"
    assert add_result.details["maxRetries"] == 1
    assert add_result.details["retryBackoffMs"] == 1_000
    assert is_binary(job_id)

    list_result = call_tool(tool, %{"action" => "list"})
    assert Enum.any?(list_result.details["jobs"], &(&1["id"] == job_id))

    update_result =
      call_tool(tool, %{
        "action" => "update",
        "id" => job_id,
        "enabled" => false,
        "maxRetries" => 2,
        "retryBackoffMs" => 2_000
      })

    assert %{"id" => ^job_id, "updated" => true, "nextRunAtMs" => _} = update_result.details

    list_after_update = call_tool(tool, %{"action" => "list"})
    updated = Enum.find(list_after_update.details["jobs"], &(&1["id"] == job_id))
    assert updated["maxRetries"] == 2
    assert updated["retryBackoffMs"] == 2_000

    pause_result = call_tool(tool, %{"action" => "pause", "id" => job_id})
    assert %{"id" => ^job_id, "paused" => true, "enabled" => false} = pause_result.details

    resume_result = call_tool(tool, %{"action" => "resume", "id" => job_id})
    assert %{"id" => ^job_id, "resumed" => true, "enabled" => true} = resume_result.details

    cron_run_id = "tool_cron_abort_run_#{System.unique_integer([:positive])}"

    run =
      job_id
      |> LemonAutomation.CronRun.new(:manual)
      |> Map.put(:id, cron_run_id)
      |> LemonAutomation.CronRun.start("tool_router_run")

    LemonAutomation.CronStore.put_run(run)

    abort_result = call_tool(tool, %{"action" => "abort", "runId" => cron_run_id})

    assert %{"runId" => ^cron_run_id, "aborted" => true, "status" => "aborted"} =
             abort_result.details

    remove_result = call_tool(tool, %{"action" => "remove", "id" => job_id})
    assert %{"removed" => true, "id" => ^job_id} = remove_result.details
  end

  test "add defaults to current session and inferred agent id when omitted" do
    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "agent_x",
        channel_id: "telegram",
        account_id: "bot",
        peer_kind: :dm,
        peer_id: "42"
      })

    tool = Cron.tool(".", session_key: session_key)

    result =
      call_tool(tool, %{
        "action" => "add",
        "schedule" => "0 * * * *",
        "prompt" => "hourly check"
      })

    assert result.details["sessionKey"] == session_key
    assert result.details["agentId"] == "agent_x"
    assert is_binary(result.details["memoryFile"])
    assert String.ends_with?(result.details["memoryFile"], "#{result.details["id"]}.md")
  end

  test "add accepts memoryFile and list returns it" do
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))
    memory_file = Path.join(System.tmp_dir!(), "cron_tool_memory_test.md")

    add_result =
      call_tool(tool, %{
        "action" => "add",
        "name" => "Memory job",
        "schedule" => "*/15 * * * *",
        "prompt" => "remember progress",
        "memoryFile" => memory_file
      })

    assert add_result.details["memoryFile"] == Path.expand(memory_file)

    list_result = call_tool(tool, %{"action" => "list"})

    listed =
      Enum.find(list_result.details["jobs"], fn job ->
        job["id"] == add_result.details["id"]
      end)

    assert listed["memoryFile"] == Path.expand(memory_file)
  end

  test "returns an error when required add fields are missing" do
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))

    result =
      call_tool(tool, %{
        "action" => "add",
        "schedule" => "* * * * *"
      })

    assert %{error: true} = result.details
    assert LemonAgent.get_text(result) =~ "prompt is required"
  end

  test "returns an error for unknown actions" do
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))
    result = call_tool(tool, %{"action" => "wat"})

    assert %{error: true} = result.details
    assert LemonAgent.get_text(result) =~ "Unknown action"
  end

  test "the application registers the tool with the agent tool registry" do
    assert {:cron, Cron, :managed} in LemonAgent.ToolRegistry.all()

    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))
    assert tool.name == "cron"
    assert tool.parameters["required"] == ["action"]
  end

  test "registered cron run persists intent and witness before command effects" do
    alias LemonCore.{NativeProcess, ProcessGroup}

    %{directory: directory, ledger: ledger} = native_ledger_context()
    assert :ok = NativeProcess.configure!(ledger)
    marker = Path.join(directory, "started")
    {tool, job} = registered_command_job(directory)
    test = self()
    capture_gate = :atomics.new(1, [])

    release_capture = fn server ->
      if :atomics.compare_exchange(capture_gate, 1, 1, 2) == :ok do
        send(server, :release_cron_capture)
      end
    end

    debug = fn state, event, _extra ->
      case event do
        {:in, {:"$gen_call", {caller, _}, {:captured, _path, id, identity}}} ->
          :atomics.put(capture_gate, 1, 1)
          send(test, {:cron_capture, self(), caller, id, identity})
          receive do: (:release_cron_capture -> :ok)

        _ ->
          :ok
      end

      state
    end

    :ok = :sys.install(NativeProcess, {debug, nil})

    on_exit(fn ->
      if server = Process.whereis(NativeProcess) do
        release_capture.(server)
        :sys.remove(server, debug)
      end
    end)

    refute call_tool(tool, %{"action" => "run", "id" => job.id}).details[:error]
    assert_receive {:cron_capture, server, caller, id, identity}, 5_000

    try do
      assert ProcessGroup.valid_identity?(identity)

      assert [{^id, %{workload_identity: nil, capacity_held: true}, %{}}] =
               persisted_native_rows(directory, ledger, id, "intent")

      refute File.exists?(marker)
      true = :erlang.suspend_process(caller)
      release_capture.(server)
      assert :ok = :sys.remove(server, debug)

      assert [{^id, %{workload_identity: witness, capacity_held: true}, %{}}] =
               persisted_native_rows(directory, ledger, id, "witness")

      assert ProcessGroup.valid_identity?(witness)
      assert Map.drop(witness, [:members]) == Map.drop(identity, [:members])
      assert Map.take(witness.members, Map.keys(identity.members)) == identity.members
      refute File.exists?(marker)
    after
      release_capture.(server)

      try do
        :erlang.resume_process(caller)
      catch
        :error, :badarg -> :ok
      end
    end

    await_command_run(job.id, :completed)
    assert File.read!(marker) == "cron-env"
    assert [run] = LemonAutomation.CronStore.list_runs(job.id)
    assert run.output == "cron-env"
  end

  test "registered cron run has no command effects when its configured ledger is unavailable" do
    %{directory: directory, ledger: ledger} = native_ledger_context()
    Application.put_env(:lemon_core, :native_process_ledger, ledger)
    refute Process.whereis(LemonCore.NativeProcess)
    {tool, job} = registered_command_job(directory)

    refute call_tool(tool, %{"action" => "run", "id" => job.id}).details[:error]
    await_command_run(job.id, :failed)
    refute File.exists?(Path.join(directory, "started"))
    refute File.exists?(ledger)
  end

  test "returns an unavailable error while the scheduler is not running" do
    :ok = Supervisor.terminate_child(LemonAutomation.Supervisor, LemonAutomation.CronManager)

    on_exit(fn ->
      Supervisor.restart_child(LemonAutomation.Supervisor, LemonAutomation.CronManager)
    end)

    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))
    result = call_tool(tool, %{"action" => "list"})

    assert %{error: true} = result.details
    assert LemonAgent.get_text(result) =~ "Cron scheduler is unavailable"
  end

  test "a job added from a non-Lemon session id (TUI) targets the agent main session" do
    tool = Cron.tool(".", session_key: "tui-20260927T081500", agent_id: "default")

    result =
      call_tool(tool, %{
        "action" => "add",
        "schedule" => "0 9 * * *",
        "prompt" => "morning check"
      })

    refute Map.get(result.details, :error)
    assert result.details["sessionKey"] == "agent:default:main"
    assert result.details["deliverTo"] == nil
    assert result.details["once"] == false
  end

  test "deliverTo and once are stored, validated, and updatable" do
    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))

    added =
      call_tool(tool, %{
        "action" => "add",
        "schedule" => "30 14 28 9 *",
        "timezone" => "local",
        "prompt" => "take the bread out",
        "deliverTo" => "telegram:-100123:7",
        "once" => true
      })

    assert added.details["deliverTo"] == "telegram:-100123:7"
    assert added.details["once"] == true
    assert added.details["timezone"] == "local"

    update =
      call_tool(tool, %{"action" => "update", "id" => added.details["id"], "deliverTo" => "none"})

    assert update.details["updated"] == true

    listed =
      call_tool(tool, %{"action" => "list"}).details["jobs"]
      |> Enum.find(&(&1["id"] == added.details["id"]))

    assert listed["deliverTo"] == "none"

    rejected =
      call_tool(tool, %{
        "action" => "add",
        "schedule" => "0 9 * * *",
        "prompt" => "nope",
        "deliverTo" => "sms:+15551234"
      })

    assert %{error: true} = rejected.details
    assert LemonAgent.get_text(rejected) =~ "deliver_to must be"
  end

  test "prompt jobs inherit cwd and accept explicit add and update targets" do
    cwd = System.tmp_dir!()
    tool = Cron.tool(cwd, session_key: "agent:default:main")
    params = %{"action" => "add", "schedule" => "hourly", "prompt" => "edit repository"}

    inherited = call_tool(tool, params)
    assert inherited.details["cwd"] == Path.expand(cwd)

    explicit =
      call_tool(
        tool,
        Map.put(params, "job", %{
          "schedule" => "hourly",
          "prompt" => "edit another repository",
          "cwd" => "/tmp/explicit-cron-repo",
          "model" => "provider:model"
        })
      )

    assert explicit.details["cwd"] == "/tmp/explicit-cron-repo"
    assert explicit.details["model"] == "provider:model"

    id = inherited.details["id"]

    updated =
      call_tool(tool, %{
        "action" => "update",
        "id" => id,
        "patch" => %{"cwd" => "/tmp/updated-cron-repo"}
      })

    assert updated.details["updated"] == true
    assert LemonAutomation.CronStore.get_job(id).cwd == "/tmp/updated-cron-repo"

    assert tool.parameters["properties"]["cwd"]["type"] == "string"
  end

  test "run history exposes coding links and bounded reconciliation status" do
    tool = Cron.tool(".", session_key: "agent:default:main")
    added = call_tool(tool, %{"action" => "add", "schedule" => "hourly", "prompt" => "work"})
    job_id = added.details["id"]

    run =
      job_id
      |> LemonAutomation.CronRun.new(:schedule)
      |> LemonAutomation.CronRun.start("router_owned")

    run = %{
      run
      | meta: %{outcome_unknown: true, router_session_key: "agent:default:main:sub:cron_owned"}
    }

    LemonAutomation.CronStore.put_run(run)

    result = call_tool(tool, %{"action" => "runs", "id" => job_id})
    assert [entry] = result.details["runs"]
    assert entry["routerRunId"] == "router_owned"
    assert entry["sessionKey"] == "agent:default:main:sub:cron_owned"
    assert entry["outcomeUnknown"] == true
    assert entry["reconciling"] == true
  end

  test "lifecycle actions resolve case-insensitive exact names without renaming the selector" do
    use_silent_submitter()
    tool = Cron.tool(".", session_key: "agent:default:main")

    added =
      call_tool(tool, %{
        "action" => "add",
        "name" => "Morning Brief",
        "schedule" => "hourly",
        "prompt" => "brief",
        "deliverTo" => "none"
      })

    id = added.details["id"]
    assert call_tool(tool, %{"action" => "pause", "name" => "MORNING BRIEF"}).details["paused"]
    refute LemonAutomation.CronStore.get_job(id).enabled
    assert call_tool(tool, %{"action" => "resume", "name" => "morning brief"}).details["resumed"]
    assert LemonAutomation.CronStore.get_job(id).enabled

    assert call_tool(tool, %{
             "action" => "update",
             "name" => "morning brief",
             "prompt" => "new prompt"
           }).details["updated"]

    assert LemonAutomation.CronStore.get_job(id).name == "Morning Brief"

    assert call_tool(tool, %{
             "action" => "update",
             "name" => "morning brief",
             "patch" => %{"name" => "Renamed"}
           }).details["updated"]

    LemonCore.Bus.subscribe("cron")
    on_exit(fn -> LemonCore.Bus.unsubscribe("cron") end)
    result = call_tool(tool, %{"action" => "run", "name" => "RENAMED"})
    refute result.details[:error]
    assert_receive %LemonCore.Event{type: :cron_run_completed}, 2_000
    assert call_tool(tool, %{"action" => "remove", "name" => "renamed"}).details["removed"]
    assert LemonAutomation.CronStore.get_job(id) == nil
  end

  test "ambiguous and unknown names list candidates and never mutate a job" do
    tool = Cron.tool(".", session_key: "agent:default:main")

    ids =
      for name <- ["Duplicate", "DUPLICATE"] do
        call_tool(tool, %{
          "action" => "add",
          "name" => name,
          "schedule" => "hourly",
          "prompt" => "test"
        }).details["id"]
      end

    for action <- ["pause", "resume", "run", "remove", "update"] do
      result =
        call_tool(tool, %{"action" => action, "name" => "duplicate", "prompt" => "changed"})

      assert result.details[:error]
      text = LemonAgent.get_text(result)
      assert text =~ "Ambiguous"
      for id <- ids, do: assert(text =~ id)
    end

    for id <- ids do
      assert LemonAutomation.CronStore.get_job(id).enabled
      assert LemonAutomation.CronStore.get_job(id).prompt == "test"
      assert LemonAutomation.CronStore.list_runs(id) == []
    end

    missing = call_tool(tool, %{"action" => "remove", "name" => "not here"})
    assert missing.details[:error]
    assert LemonAgent.get_text(missing) =~ "Cron job not found:"
    for id <- ids, do: assert(LemonAgent.get_text(missing) =~ id)

    [id | _] = ids

    assert call_tool(tool, %{"action" => "pause", "id" => id, "name" => "duplicate"}).details[
             "paused"
           ]

    unknown_id =
      call_tool(tool, %{"action" => "remove", "id" => "missing-id", "name" => "Duplicate"})

    assert LemonAgent.get_text(unknown_id) =~ "Cron job not found: missing-id"
  end

  test "relative one-shots pin their slot, run once and retire; past ISO schedules reject" do
    use_silent_submitter()
    tool = Cron.tool(".", session_key: "agent:default:main")
    before = LemonCore.Clock.now_ms()

    added =
      call_tool(tool, %{
        "action" => "add",
        "name" => "Relative",
        "schedule" => "in 30m",
        "prompt" => "reminder",
        "once" => false,
        "deliverTo" => "none"
      })

    id = added.details["id"]
    job = LemonAutomation.CronStore.get_job(id)
    assert job.once
    assert job.next_run_at_ms >= before + 1_800_000
    assert job.next_run_at_ms <= LemonCore.Clock.now_ms() + 1_800_000
    refute job.schedule == "in 30m"

    assert call_tool(tool, %{"action" => "update", "id" => id, "once" => false}).details[
             "updated"
           ]

    assert LemonAutomation.CronStore.get_job(id).once

    past =
      call_tool(tool, %{"action" => "add", "schedule" => "2000-01-01T09:00", "prompt" => "old"})

    assert LemonAgent.get_text(past) =~ "must be in the future"

    rejected_update =
      call_tool(tool, %{
        "action" => "update",
        "id" => id,
        "patch" => %{"schedule" => "2000-01-01T09:00"}
      })

    assert LemonAgent.get_text(rejected_update) =~ "must be in the future"

    updated =
      call_tool(tool, %{"action" => "update", "id" => id, "patch" => %{"schedule" => "in 2h"}})

    assert updated.details["updated"]
    job = %{LemonAutomation.CronStore.get_job(id) | next_run_at_ms: LemonCore.Clock.now_ms() - 1}
    LemonAutomation.CronStore.put_job(job)
    :sys.replace_state(LemonAutomation.CronManager, fn state -> put_in(state.jobs[id], job) end)
    LemonCore.Bus.subscribe("cron")
    on_exit(fn -> LemonCore.Bus.unsubscribe("cron") end)
    LemonAutomation.CronManager.tick()
    assert_receive %LemonCore.Event{type: :cron_run_completed}, 2_000
    _ = LemonAutomation.CronManager.list()
    assert LemonAutomation.CronStore.get_job(id) == nil
    assert [run] = LemonAutomation.CronStore.list_runs(id)
    assert run.suppressed
    LemonAutomation.CronManager.tick()
    _ = LemonAutomation.CronManager.list()
    assert [_] = LemonAutomation.CronStore.list_runs(id)
  end

  test "ISO schedules honor job timezone and automatically become one-shots" do
    tool = Cron.tool(".", session_key: "agent:default:main")
    year = Date.utc_today().year + 1

    result =
      call_tool(tool, %{
        "action" => "add",
        "name" => "Local timestamp",
        "schedule" => "#{year}-07-15T09:30:45",
        "timezone" => "America/New_York",
        "prompt" => "reminder"
      })

    job = LemonAutomation.CronStore.get_job(result.details["id"])
    assert job.once
    assert job.schedule == "#{year}-07-15T13:30:45.000Z"

    assert job.next_run_at_ms ==
             DateTime.to_unix(DateTime.new!(Date.new!(year, 7, 15), ~T[13:30:45]), :millisecond)
  end

  defp native_ledger_context do
    original = Application.fetch_env(:lemon_core, :native_process_ledger)
    directory = Path.join(System.tmp_dir!(), "cron-native-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    on_exit(fn ->
      if pid = Process.whereis(LemonCore.NativeProcess) do
        for {_id, record, %{}} <- LemonCore.NativeProcess.snapshot() do
          if LemonCore.ProcessGroup.valid_identity?(record.workload_identity) do
            LemonCore.ProcessGroup.signal_workload_group(record.workload_identity, :sigkill)
          end
        end

        GenServer.stop(pid)
      end

      table = :lemon_native_processes_dets
      if :dets.info(table) != :undefined, do: :dets.close(table)

      case original do
        {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
        :error -> Application.delete_env(:lemon_core, :native_process_ledger)
      end

      File.rm_rf!(directory)
    end)

    %{directory: directory, ledger: Path.join(directory, "processes.dets")}
  end

  defp registered_command_job(directory) do
    assert {:cron, module, :managed} =
             Enum.find(LemonAgent.ToolRegistry.all(), &(elem(&1, 0) == :cron))

    tool = module.tool(directory, session_key: LemonCore.SessionKey.main("default"))

    {:ok, job} =
      LemonAutomation.CronManager.add(%{
        name: "native command",
        schedule: "hourly",
        enabled: false,
        command: "printf '%s' \"$CRON_NATIVE_TEST\" > started; printf '%s' \"$CRON_NATIVE_TEST\"",
        cwd: directory,
        env: %{"CRON_NATIVE_TEST" => "cron-env"},
        timeout_ms: 5_000
      })

    {tool, job}
  end

  defp persisted_native_rows(directory, ledger, id, suffix) do
    copy = Path.join(directory, suffix <> ".dets")
    File.cp!(ledger, copy)

    {:ok, table} =
      :dets.open_file(:cron_native_test_copy, file: String.to_charlist(copy), repair: false)

    try do
      :dets.lookup(table, id)
    after
      :dets.close(table)
    end
  end

  defp await_command_run(job_id, status, attempts \\ 250)

  defp await_command_run(job_id, status, 0) do
    assert [%{status: ^status}] = LemonAutomation.CronStore.list_runs(job_id)
  end

  defp await_command_run(job_id, status, attempts) do
    case LemonAutomation.CronStore.list_runs(job_id) do
      [%{status: ^status}] ->
        :ok

      _ ->
        Process.sleep(20)
        await_command_run(job_id, status, attempts - 1)
    end
  end

  defp use_silent_submitter do
    previous = Application.get_env(:lemon_automation, :cron_run_submitter)
    Application.put_env(:lemon_automation, :cron_run_submitter, SilentSubmitter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_automation, :cron_run_submitter, previous),
        else: Application.delete_env(:lemon_automation, :cron_run_submitter)
    end)
  end

  defp call_tool(tool, params) do
    tool.execute.("call_1", params, nil, nil)
  end

  defp clear_cron_data do
    if Process.whereis(LemonAutomation.CronManager) do
      LemonAutomation.CronManager.list()
      |> Enum.each(fn job ->
        _ = LemonAutomation.CronManager.remove(job.id)
      end)
    end

    LemonCore.Store.list(:cron_jobs)
    |> Enum.each(fn {job_id, _} ->
      LemonCore.Store.delete(:cron_jobs, job_id)
    end)

    LemonCore.Store.list(:cron_runs)
    |> Enum.each(fn {run_id, _} ->
      LemonCore.Store.delete(:cron_runs, run_id)
    end)
  end
end
