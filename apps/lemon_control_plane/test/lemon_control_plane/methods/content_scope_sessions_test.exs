defmodule LemonControlPlane.Methods.ContentScopeSessionsTest do
  @moduledoc """
  `operator.read` is metadata-only for the session, subagent, run, cron-audit
  and process-job read methods: previews, transcript text, steer previews,
  tree entry text, subagent descriptions/activity, free-text run and audit
  errors, process commands/output and diffs need `operator.content`, and a
  content-searching `query` is refused without it.
  """
  use ExUnit.Case, async: false

  alias LemonAutomation.CronStore
  alias LemonControlPlane.Methods.Registry
  alias LemonCore.{IntrospectionStore, RunStore, SessionLifecycle, Store}

  @prose "The merger closes Friday at 41 dollars per share"
  @unlabelled "PROMPT_SECRET_7Q2X9"
  @content "#{@prose}; reference #{@unlabelled}"

  defmodule FakeRuntime do
    @moduledoc false
    @content "The merger closes Friday at 41 dollars per share; reference PROMPT_SECRET_7Q2X9"

    def session_tree(_key, _cwd, _opts) do
      {:ok,
       %{
         "sessionId" => "s1",
         "leafId" => "e2",
         "totalEntries" => 2,
         "offset" => 0,
         "hasMore" => false,
         "entries" => [
           %{
             "id" => "e1",
             "parentId" => nil,
             "type" => "message",
             "role" => "user",
             "text" => @content,
             "timestamp" => 1,
             "isActive" => true,
             "isLeaf" => false,
             "rewindable" => true,
             "label" => "bookmark #{@content}"
           }
         ],
         "branches" => [%{"leafId" => "e2", "active" => true}]
       }}
    end

    def session_pending_steers(_key),
      do: {:ok, [%{id: "steer-1", text: @content, accepted_after_turn: 2}]}

    def subagents_list(_key) do
      {:ok,
       [
         %{
           task_id: "t1",
           status: "running",
           depth: 0,
           name: "Researcher",
           agent: "scout",
           description: "Investigate #{@content}",
           model: "anthropic/claude-sonnet-4-5",
           activity: "reading #{@content}",
           created_at_ms: 1_000,
           usage: %{tokens: 12}
         }
       ]}
    end

    def subagent_transcript(_key, "t1"),
      do:
        {:ok, %{task_id: "t1", status: "running", text: "# Task\n#{@content}", truncated: false}}

    def session_jobs(_key) do
      {:ok,
       %{
         root_id: "root",
         now_ms: 10,
         total: 1,
         jobs: [job()],
         agents: [%{id: "root", parent_id: nil, name: "main"}]
       }}
    end

    def session_job(_key, "job1", _opts) do
      {:ok,
       Map.merge(job(), %{
         cwd: "/tmp/work",
         backend: :local,
         pids: [123],
         output: "out: #{@content}",
         output_truncated: false,
         output_bytes: 200
       })}
    end

    defp job do
      %{
        id: "job1",
        status: :running,
        owner_id: "root",
        command: "echo '#{@content}'",
        started_ms: 1,
        launch: :bash,
        exit_code: nil
      }
    end
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, FakeRuntime)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:lemon_core, :agent_runtime_provider),
        else: Application.put_env(:lemon_core, :agent_runtime_provider, original)
    end)

    %{token: System.unique_integer([:positive])}
  end

  defp read_only, do: %{auth: %{role: :operator, scopes: [:read]}}
  defp with_content, do: %{auth: %{role: :operator, scopes: [:read, :content]}}

  defp dispatch(method, params, ctx) do
    assert {:ok, result} = Registry.dispatch(method, params, ctx)
    result
  end

  defp assert_withheld(payload) do
    encoded = Jason.encode!(payload)
    refute encoded =~ "merger closes Friday"
    refute encoded =~ @unlabelled
    refute inspect(payload) =~ @unlabelled
  end

  defp assert_content(payload) do
    encoded = Jason.encode!(payload)
    assert encoded =~ "merger closes Friday"
    assert encoded =~ @unlabelled
  end

  defp session(token) do
    key = "agent:content_sessions_#{token}:main"
    agent = LemonCore.SessionKey.agent_id(key)
    :ok = RunStore.create_session_index(key, agent, :tui)
    run_id = "content-sessions-run-#{token}"

    :ok =
      RunStore.finalize(run_id, %{
        session_key: key,
        agent_id: agent,
        origin: :tui,
        prompt: "Please summarise: #{@content}",
        completed: %{ok: true, answer: "Answer: #{@content}"}
      })

    on_exit(fn ->
      SessionLifecycle.delete(key)
      Store.delete(:runs, run_id)
    end)

    {key, agent, run_id}
  end

  describe "sessions.preview" do
    test "read-only callers get run metadata without prompt or answer previews", c do
      {key, _agent, run_id} = session(c.token)
      result = dispatch("sessions.preview", %{"sessionKey" => key}, read_only())
      assert_withheld(result)
      assert [entry] = result["preview"]
      assert entry["runId"] == run_id
      assert entry["ok"] == true
      assert entry["promptBytes"] > 0
      assert entry["answerBytes"] > 0
      assert result["contentWithheld"] == true
    end

    test "operator.content callers get previews", c do
      {key, _agent, _run_id} = session(c.token)
      result = dispatch("sessions.preview", %{"sessionKey" => key}, with_content())
      assert_content(result)
      assert result["contentWithheld"] == false
    end
  end

  describe "sessions.list / sessions.stats query" do
    test "read-only callers cannot search transcript text", c do
      {_key, agent, _run_id} = session(c.token)

      assert {:error, {:forbidden, _, _}} =
               Registry.dispatch(
                 "sessions.list",
                 %{"agentId" => agent, "query" => "merger closes"},
                 read_only()
               )

      assert {:error, {:forbidden, _, _}} =
               Registry.dispatch(
                 "sessions.stats",
                 %{"agentId" => agent, "query" => "merger closes"},
                 read_only()
               )

      listed = dispatch("sessions.list", %{"agentId" => agent}, read_only())
      assert listed["total"] == 1
      assert listed["contentWithheld"] == true
    end

    test "operator.content callers can search transcript text", c do
      {key, agent, _run_id} = session(c.token)
      params = %{"agentId" => agent, "query" => "merger closes"}
      listed = dispatch("sessions.list", params, with_content())
      assert [%{"sessionKey" => ^key}] = listed["sessions"]
      assert listed["contentWithheld"] == false

      stats = dispatch("sessions.stats", params, with_content())
      assert stats["totals"]["matchedSessions"] == 1
    end
  end

  describe "sessions.tree" do
    @params %{"sessionKey" => "agent:x:main", "cwd" => "/tmp"}

    test "read-only callers get tree structure without entry text" do
      result = dispatch("sessions.tree", @params, read_only())
      assert_withheld(result)
      assert [entry] = result["entries"]
      assert entry["id"] == "e1"
      assert entry["role"] == "user"
      assert entry["textBytes"] == byte_size(@content)
      assert result["contentWithheld"] == true
    end

    test "operator.content callers get entry text" do
      assert_content(dispatch("sessions.tree", @params, with_content()))
    end
  end

  describe "sessions.steer.pending" do
    test "read-only callers get steer identities without previews" do
      result = dispatch("sessions.steer.pending", %{"sessionKey" => "agent:x:main"}, read_only())
      assert_withheld(result)
      assert [%{"messageId" => "steer-1", "acceptedAfterTurn" => 2} = item] = result["items"]
      assert item["previewBytes"] == byte_size(@content)
      assert result["contentWithheld"] == true
    end

    test "operator.content callers get previews" do
      params = %{"sessionKey" => "agent:x:main"}
      assert_content(dispatch("sessions.steer.pending", params, with_content()))
    end
  end

  describe "subagents" do
    test "read-only callers get roster metadata and no transcript text" do
      list = dispatch("subagents.list", %{"sessionKey" => "agent:x:main"}, read_only())
      assert_withheld(list)
      assert [agent] = list["agents"]
      assert agent["taskId"] == "t1"
      assert agent["status"] == "running"
      assert agent["name"] == "Researcher"
      assert agent["usage"]["tokens"] == 12
      refute Map.has_key?(agent, "description")
      refute Map.has_key?(agent, "activity")
      assert list["contentWithheld"] == true

      params = %{"sessionKey" => "agent:x:main", "taskId" => "t1"}
      transcript = dispatch("subagents.transcript", params, read_only())
      assert_withheld(transcript)
      assert transcript["status"] == "running"
      assert transcript["textBytes"] > 0
      refute Map.has_key?(transcript, "text")
      assert transcript["contentWithheld"] == true
    end

    test "operator.content callers get descriptions and transcript text" do
      assert_content(
        dispatch("subagents.list", %{"sessionKey" => "agent:x:main"}, with_content())
      )

      params = %{"sessionKey" => "agent:x:main", "taskId" => "t1"}
      assert_content(dispatch("subagents.transcript", params, with_content()))
    end
  end

  describe "process.jobs" do
    test "read-only callers get job metadata without command or output" do
      list = dispatch("process.jobs.list", %{"sessionKey" => "agent:x:main"}, read_only())
      assert_withheld(list)
      assert [job] = list["jobs"]
      assert job["id"] == "job1"
      assert job["status"] == "running"
      assert job["commandBytes"] > 0
      assert list["contentWithheld"] == true

      params = %{"sessionKey" => "agent:x:main", "jobId" => "job1"}
      detail = dispatch("process.jobs.inspect", params, read_only())
      assert_withheld(detail)
      assert detail["job"]["outputBytes"] == 200
      assert detail["job"]["pids"] == [123]
      assert detail["contentWithheld"] == true
    end

    test "operator.content callers get command and output" do
      assert_content(
        dispatch("process.jobs.list", %{"sessionKey" => "agent:x:main"}, with_content())
      )

      params = %{"sessionKey" => "agent:x:main", "jobId" => "job1"}
      detail = dispatch("process.jobs.inspect", params, with_content())
      assert_content(detail)
      assert detail["job"]["output"] =~ @unlabelled
    end
  end

  describe "runs.recent.list" do
    setup c do
      key = "agent:content_runs_#{c.token}:main"
      run_id = "content-runs-#{c.token}"

      :ok =
        IntrospectionStore.append(%{
          event_id: "evt-#{c.token}",
          event_type: :run_completed,
          ts_ms: System.system_time(:millisecond),
          run_id: run_id,
          session_key: key,
          agent_id: "content_runs",
          engine: "native",
          provenance: :direct,
          payload: %{ok: false, error: "failed on #{@content}", duration_ms: 5}
        })

      %{key: key, run_id: run_id}
    end

    test "read-only callers get status without free-text errors", c do
      result = dispatch("runs.recent.list", %{"sessionKey" => c.key}, read_only())
      assert_withheld(result)
      assert [run] = result["runs"]
      assert run["runId"] == c.run_id
      assert run["status"] == "error"
      assert run["durationMs"] == 5
      assert result["contentWithheld"] == true
    end

    test "operator.content callers get the error text", c do
      assert_content(dispatch("runs.recent.list", %{"sessionKey" => c.key}, with_content()))
    end
  end

  describe "cron.audit" do
    setup c do
      job_id = "content_audit_job_#{c.token}"

      CronStore.record_audit(:run_failed, %{
        job_id: job_id,
        run_id: "content_audit_run_#{c.token}",
        status: :failed,
        triggered_by: :manual,
        reason: "failed on #{@content}"
      })

      CronStore.record_audit(:scheduled_run_suppressed, %{job_id: job_id, reason: :global_pause})
      %{job_id: job_id}
    end

    test "read-only callers get audit metadata and enum reasons only", c do
      result = dispatch("cron.audit", %{"jobId" => c.job_id}, read_only())
      assert_withheld(result)
      assert result["total"] == 2
      assert Enum.any?(result["events"], &(&1["reason"] == "global_pause"))
      assert result["contentWithheld"] == true
    end

    test "operator.content callers get free-text reasons", c do
      assert_content(dispatch("cron.audit", %{"jobId" => c.job_id}, with_content()))
    end
  end

  describe "sessions.changes diff" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "lemon-cs-changes-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      git = fn args ->
        {_, 0} =
          System.cmd(
            "git",
            ["-c", "user.email=t@example.com", "-c", "user.name=T" | args],
            cd: root,
            stderr_to_stdout: true,
            env: [{"GIT_CONFIG_NOSYSTEM", "1"}]
          )
      end

      git.(["init", "-q"])
      File.write!(Path.join(root, "notes.txt"), "one\n")
      git.(["add", "-A"])
      git.(["commit", "-q", "-m", "init"])
      File.write!(Path.join(root, "notes.txt"), "one\n#{@content}\n")
      %{root: root}
    end

    test "read-only callers get diff counts without the patch", %{root: root} do
      params = %{"sessionKey" => "agent:x:main", "cwd" => root, "path" => "notes.txt"}
      result = dispatch("sessions.changes", params, read_only())
      assert_withheld(result)
      assert result["diff"]["path"] == "notes.txt"
      assert result["diff"]["additions"] == 1
      assert result["diff"]["patchBytes"] > 0
      refute Map.has_key?(result["diff"], "patch")
      assert result["contentWithheld"] == true
    end

    test "operator.content callers get the patch", %{root: root} do
      params = %{"sessionKey" => "agent:x:main", "cwd" => root, "path" => "notes.txt"}
      assert_content(dispatch("sessions.changes", params, with_content()))
    end
  end
end
