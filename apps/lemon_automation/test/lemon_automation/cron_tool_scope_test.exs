defmodule LemonAutomation.CronToolScopeTest do
  @moduledoc """
  What an agent session can reach through the `cron` tool: only jobs its own
  principal (session key) created, only Lemon-owned per-job memory files, and
  never the operator-wide pause. Operator surfaces (`CronManager`) are unchanged.
  """
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronMemory, CronRun, CronStore, RunSubmitter}
  alias LemonAutomation.Tools.Cron
  alias LemonCore.{SessionKey, ToolPolicy}

  @moduletag :tmp_dir

  defmodule AbortRouter do
    def abort_run(_id, _reason), do: :ok
  end

  defmodule SilentSubmitter do
    def submit(_job, _run, _opts), do: {:ok, "[SILENT]"}
  end

  setup %{tmp_dir: root} do
    config = Path.join(root, "config.toml")
    File.write!(config, "")
    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_router = Application.get_env(:lemon_automation, :cron_router_mod)
    previous_submitter = Application.get_env(:lemon_automation, :cron_run_submitter)

    Application.put_env(
      :lemon_core,
      :paths,
      (previous_paths || [])
      |> Keyword.put(:global_config, config)
      |> Keyword.put(:home_state_dir, root)
    )

    Application.put_env(:lemon_automation, :cron_router_mod, AbortRouter)
    Application.put_env(:lemon_automation, :cron_run_submitter, SilentSubmitter)
    {:ok, _} = Application.ensure_all_started(:lemon_automation)
    clear_cron_data()

    on_exit(fn ->
      clear_cron_data()
      _ = CronStore.clear_global_pause()
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_automation, :cron_router_mod, previous_router)
      restore_env(:lemon_automation, :cron_run_submitter, previous_submitter)
    end)

    :ok
  end

  describe "memory file confinement" do
    test "the cron tool refuses a model-chosen memory file on add and update", %{tmp_dir: root} do
      tool = Cron.tool(root, session_key: chat_key(), agent_id: "default")
      outside = Path.join(root, "outside/notes.md")

      refused =
        call_tool(tool, %{
          "action" => "add",
          "name" => "memory escape",
          "schedule" => "0 0 1 1 *",
          "prompt" => "hello",
          "memoryFile" => outside
        })

      assert refused.details[:error] == true
      assert refused.details[:message] =~ "memoryFile"
      assert CronManager.list() == []

      added = add_job(tool, "owned memory")
      job = CronStore.get_job(added["id"])
      assert added["memoryFile"] == owned_memory_path(root, job.id)

      for patch <- [%{"memoryFile" => outside}, %{"patch" => %{"memory_file" => outside}}] do
        result = call_tool(tool, Map.merge(%{"action" => "update", "id" => job.id}, patch))
        assert result.details[:error] == true
        assert result.details[:message] =~ "memoryFile"
      end

      assert CronMemory.memory_file(CronStore.get_job(job.id)) == owned_memory_path(root, job.id)
    end

    test "a persisted legacy memory path is never read or written", %{tmp_dir: root} do
      secret = Path.join(root, "outside/secret.md")
      File.mkdir_p!(Path.dirname(secret))
      File.write!(secret, "SECRET-CONTENT")
      job = operator_job("legacy")

      legacy =
        job
        |> CronJob.to_storage_map()
        |> Map.put(:memory_file, secret)
        |> Map.put(:meta, %{"memory_file" => secret, "memoryFile" => secret})
        |> CronJob.from_map()

      run = CronRun.new(legacy.id, :manual)
      params = RunSubmitter.build_params(legacy, run, LemonCore.Id.run_id())

      refute params.prompt =~ "SECRET-CONTENT"
      assert params.meta.cron_memory_file == owned_memory_path(root, legacy.id)

      assert :ok = CronMemory.append_run(legacy, run, SessionKey.main("default"), {:ok, "done"})
      assert File.read!(secret) == "SECRET-CONTENT"
      assert File.read!(owned_memory_path(root, legacy.id)) =~ "done"
    end

    test "a symlinked memory file is neither read nor written through", %{tmp_dir: root} do
      secret = Path.join(root, "outside/secret.md")
      File.mkdir_p!(Path.dirname(secret))
      File.write!(secret, "SECRET-CONTENT")
      job = operator_job("symlinked")
      owned = owned_memory_path(root, job.id)
      File.mkdir_p!(Path.dirname(owned))
      File.ln_s!(secret, owned)

      run = CronRun.new(job.id, :manual)
      params = RunSubmitter.build_params(job, run, LemonCore.Id.run_id())
      refute params.prompt =~ "SECRET-CONTENT"

      assert :ok = CronMemory.append_run(job, run, SessionKey.main("default"), {:ok, "done"})
      assert File.read!(secret) == "SECRET-CONTENT"
    end

    test "a job id cannot steer the memory path out of the cron memory directory",
         %{tmp_dir: root} do
      for id <- ["../../escape", "/etc/passwd", "a/b", ".."] do
        job = CronJob.new(%{id: id, name: "x", schedule: "0 0 1 1 *"})
        path = CronMemory.memory_file(job)
        assert Path.dirname(path) == Path.join(root, "cron_memory"), inspect({id, path})
      end
    end

    test "a hard-linked memory file is neither read nor written through", %{tmp_dir: root} do
      secret = write_secret(root)
      job = operator_job("hardlinked")
      owned = owned_memory_path(root, job.id)
      File.mkdir_p!(Path.dirname(owned))
      File.ln!(secret, owned)

      run = CronRun.new(job.id, :manual)
      params = RunSubmitter.build_params(job, run, LemonCore.Id.run_id())
      refute params.prompt =~ "SECRET-CONTENT"

      assert :ok = CronMemory.append_run(job, run, SessionKey.main("default"), {:ok, "done"})
      assert File.read!(secret) == "SECRET-CONTENT"
      assert File.stat!(secret).links == 2
    end

    test "appending replaces the memory file by rename, never in place", %{tmp_dir: root} do
      job = operator_job("rename")
      owned = owned_memory_path(root, job.id)
      File.mkdir_p!(Path.dirname(owned))
      File.write!(owned, "# Cron Memory: rename\n")
      before = File.lstat!(owned)

      run = CronRun.new(job.id, :manual)
      assert :ok = CronMemory.append_run(job, run, SessionKey.main("default"), {:ok, "done"})

      after_append = File.lstat!(owned)
      refute after_append.inode == before.inode
      assert after_append.links == 1
      assert File.read!(owned) =~ "# Cron Memory: rename"
      assert File.read!(owned) =~ "done"
      assert File.ls!(Path.dirname(owned)) == [Path.basename(owned)]
    end

    test "a memory file substituted after the check is not read", %{tmp_dir: root} do
      secret = write_secret(root)
      job = operator_job("read swap")
      owned = owned_memory_path(root, job.id)
      File.mkdir_p!(Path.dirname(owned))

      swaps = [
        fn -> File.ln_s!(secret, owned) end,
        fn -> File.ln!(secret, owned) end,
        fn ->
          other = owned <> ".other"
          File.write!(other, "OTHER-CONTENT")
          File.rename!(other, owned)
        end
      ]

      for swap <- swaps do
        File.rm_rf!(owned)
        File.write!(owned, "original")

        before_open = fn ->
          File.rm!(owned)
          swap.()
        end

        assert {:error, _} = CronMemory.read_confined(owned, before_open: before_open)
      end

      assert File.read!(secret) == "SECRET-CONTENT"
    end

    test "a memory entry or directory substituted before the rename is not written through",
         %{tmp_dir: root} do
      secret = write_secret(root)
      outside = Path.join(root, "outside")
      job = operator_job("write swap")
      owned = owned_memory_path(root, job.id)
      dir = Path.dirname(owned)

      swaps = [
        fn -> File.rm!(owned) && File.ln_s!(secret, owned) end,
        fn -> File.ln!(owned, owned <> ".alias") end,
        fn -> File.rm!(owned) && File.write!(owned, "replaced") end,
        fn ->
          File.rename!(dir, dir <> ".old")
          File.ln_s!(outside, dir)
        end
      ]

      for swap <- swaps do
        File.rm_rf!(dir)
        File.rm_rf!(dir <> ".old")
        File.mkdir_p!(dir)
        File.write!(owned, "original")
        assert {:ok, "original", stat} = CronMemory.read_confined(owned)

        assert {:error, _} =
                 CronMemory.replace_confined(owned, "NEW", stat, before_rename: swap)

        assert File.read!(secret) == "SECRET-CONTENT"
        assert File.ls!(outside) == ["secret.md"]
      end

      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      assert :ok = CronMemory.replace_confined(owned, "NEW", :absent)
      assert File.read!(owned) == "NEW"
      assert {:error, :memory_changed} = CronMemory.replace_confined(owned, "X", :absent)
      assert File.ls!(dir) == [Path.basename(owned)]
    end
  end

  describe "ownership" do
    test "another chat cannot see or control a chat's job", %{tmp_dir: root} do
      owner = Cron.tool(root, session_key: chat_key(), agent_id: "default")
      other = Cron.tool(root, session_key: chat_key(), agent_id: "default")
      job_id = add_job(owner, "a-job")["id"]
      run = start_run(job_id)

      assert call_tool(other, %{"action" => "list"}).details["jobs"] == []
      assert call_tool(other, %{"action" => "status"}).details["jobCount"] == 0

      for params <- [
            %{"action" => "run", "id" => job_id},
            %{"action" => "pause", "id" => job_id},
            %{"action" => "resume", "id" => job_id},
            %{"action" => "runs", "id" => job_id},
            %{"action" => "update", "id" => job_id, "prompt" => "rm -rf /"},
            %{"action" => "pause", "name" => "a-job"},
            %{"action" => "update", "name" => "a-job", "patch" => %{"prompt" => "x"}},
            %{"action" => "remove", "id" => job_id},
            %{"action" => "abort", "runId" => run.id}
          ] do
        result = call_tool(other, params)
        assert result.details[:error] == true, inspect(params)
        assert result.details[:message] =~ "not found", inspect(params)
      end

      job = CronStore.get_job(job_id)
      assert job.prompt == "hello"
      assert job.enabled == false
      assert CronStore.list_runs(job_id) |> Enum.map(& &1.status) == [:running]
    end

    test "operator jobs are out of reach of agent sessions", %{tmp_dir: root} do
      job = operator_job("operator")
      tool = Cron.tool(root, session_key: SessionKey.main("default"), agent_id: "default")

      assert call_tool(tool, %{"action" => "list"}).details["jobs"] == []

      for action <- ["run", "pause", "remove"] do
        assert call_tool(tool, %{"action" => action, "id" => job.id}).details[:message] =~
                 "not found"
      end

      assert {:ok, _} = CronManager.update(job.id, %{enabled: true})
      assert CronStore.get_job(job.id).enabled
    end

    test "the owning session manages its own job", %{tmp_dir: root} do
      key = chat_key()
      tool = Cron.tool(root, session_key: key, agent_id: "default")
      job_id = add_job(tool, "mine")["id"]

      # A later session of the same principal (e.g. after restart) reaches it.
      tool = Cron.tool(root, session_key: key, agent_id: "default")
      assert [%{"id" => ^job_id}] = call_tool(tool, %{"action" => "list"}).details["jobs"]
      assert call_tool(tool, %{"action" => "resume", "name" => "MINE"}).details["enabled"]
      assert call_tool(tool, %{"action" => "pause", "id" => job_id}).details["paused"]

      assert call_tool(tool, %{"action" => "update", "id" => job_id, "prompt" => "new"}).details[
               "updated"
             ]

      assert call_tool(tool, %{"action" => "runs", "id" => job_id}).details["runs"] == []
      assert call_tool(tool, %{"action" => "remove", "id" => job_id}).details["removed"]
    end

    test "a session without an identity cannot schedule or list", %{tmp_dir: root} do
      tool = Cron.tool(root, agent_id: "default")
      result = call_tool(tool, %{"action" => "add", "schedule" => "0 0 1 1 *", "prompt" => "x"})

      assert result.details[:error] == true
      assert CronManager.list() == []
      assert call_tool(tool, %{"action" => "list"}).details[:error] == true
    end

    test "CronManager.update_from_session refuses another principal's job", %{tmp_dir: root} do
      job_id = add_job(Cron.tool(root, session_key: chat_key(), agent_id: "default"), "j")["id"]

      assert {:error, :not_found} =
               CronManager.update_from_session(job_id, %{prompt: "x"}, session_key: chat_key())

      assert CronStore.get_job(job_id).prompt == "hello"
    end

    test "legacy session ids own distinct jobs and are never promoted to main",
         %{tmp_dir: root} do
      main = SessionKey.main("default")
      legacy_a = Cron.tool(root, session_key: "tui-1700000000001", agent_id: "default")
      legacy_b = Cron.tool(root, session_key: "tui-1700000000002", agent_id: "default")
      canonical = Cron.tool(root, session_key: main, agent_id: "default")

      ids =
        for {tool, name} <- [{legacy_a, "a"}, {legacy_b, "b"}, {canonical, "m"}], into: %{} do
          {name, add_job(tool, name)["id"]}
        end

      for {tool, own} <- [{legacy_a, "a"}, {legacy_b, "b"}, {canonical, "m"}] do
        assert [%{"id" => id}] = call_tool(tool, %{"action" => "list"}).details["jobs"]
        assert id == ids[own]

        for {other, other_id} <- ids, other != own do
          for action <- ["run", "pause", "remove", "runs"] do
            assert call_tool(tool, %{"action" => action, "id" => other_id}).details[:message] =~
                     "not found"
          end
        end
      end

      # Delivery still falls back to the agent's main session; ownership does not.
      legacy_job = CronStore.get_job(ids["a"])
      assert legacy_job.session_key == main
      assert "legacy:" <> _ = legacy_job.authority["owner"]
      refute legacy_job.authority["owner"] == CronStore.get_job(ids["b"]).authority["owner"]
      assert CronStore.get_job(ids["m"]).authority["owner"] == main
    end

    test "run executes within the triggering session's policy", %{tmp_dir: root} do
      key = chat_key()
      job_id = add_job(Cron.tool(root, session_key: key, agent_id: "default"), "trigger")["id"]

      restricted =
        Cron.tool(root,
          session_key: key,
          agent_id: "default",
          tool_policy: %{"profile" => "no_external"}
        )

      run_id = call_tool(restricted, %{"action" => "run", "id" => job_id}).details["runId"]
      run = CronStore.get_run(run_id)
      params = RunSubmitter.build_params(CronStore.get_job(job_id), run, LemonCore.Id.run_id())

      refute ToolPolicy.allowed?(params.tool_policy, "webfetch")
      refute ToolPolicy.allowed?(params.tool_policy, "websearch")

      assert {:error, :not_found} =
               CronManager.run_now_from_session(job_id, session_key: chat_key())
    end
  end

  test "pause_all and resume_all are operator-only", %{tmp_dir: root} do
    tool = Cron.tool(root, session_key: SessionKey.main("default"), agent_id: "default")

    paused = call_tool(tool, %{"action" => "pause_all"})
    assert paused.details[:error] == true
    assert paused.details[:message] =~ "operator"
    assert {:ok, %{paused: false}} = CronManager.pause_status()

    # Set the durable marker directly so no operator pause audit outlives the test.
    assert :ok = CronStore.put_global_pause(LemonCore.Clock.now_ms())
    resumed = call_tool(tool, %{"action" => "resume_all"})
    assert resumed.details[:error] == true
    assert {:ok, %{paused: true}} = CronManager.pause_status()
    refute "pause_all" in tool.parameters["properties"]["action"]["enum"]
  end

  defp add_job(tool, name) do
    result =
      call_tool(tool, %{
        "action" => "add",
        "name" => name,
        "schedule" => "0 0 1 1 *",
        "prompt" => "hello",
        "enabled" => false
      })

    refute result.details[:error], inspect(result.details)
    result.details
  end

  defp operator_job(name) do
    {:ok, job} =
      CronManager.add(%{
        name: name,
        schedule: "0 0 1 1 *",
        agent_id: "default",
        session_key: SessionKey.main("default"),
        prompt: "hello",
        enabled: false
      })

    job
  end

  defp start_run(job_id) do
    run = job_id |> CronRun.new(:manual) |> CronRun.start("router_run_#{job_id}")
    CronStore.put_run(run)
    run
  end

  defp chat_key do
    SessionKey.channel_peer(%{
      agent_id: "default",
      channel_id: "telegram",
      account_id: "default",
      peer_kind: :group,
      peer_id: "-100#{System.unique_integer([:positive])}"
    })
  end

  defp owned_memory_path(root, id), do: Path.join([root, "cron_memory", id <> ".md"])

  defp write_secret(root) do
    secret = Path.join(root, "outside/secret.md")
    File.mkdir_p!(Path.dirname(secret))
    File.write!(secret, "SECRET-CONTENT")
    secret
  end

  defp call_tool(tool, params), do: tool.execute.("call_1", params, nil, nil)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp clear_cron_data do
    if Process.whereis(CronManager) do
      Enum.each(CronManager.list(), &CronManager.remove(&1.id))
    end

    for {id, _} <- LemonCore.Store.list(:cron_jobs), do: LemonCore.Store.delete(:cron_jobs, id)
    for {id, _} <- LemonCore.Store.list(:cron_runs), do: LemonCore.Store.delete(:cron_runs, id)
  end
end
