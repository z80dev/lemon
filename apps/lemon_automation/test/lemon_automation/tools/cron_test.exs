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
    assert {:cron, Cron} in LemonAgent.ToolRegistry.all()

    tool = Cron.tool(".", session_key: LemonCore.SessionKey.main("default"))
    assert tool.name == "cron"
    assert tool.parameters["required"] == ["action"]
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
