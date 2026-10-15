defmodule LemonAutomation.RunSubmitterTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronRun, RunSubmitter}
  alias LemonCore.SessionKey

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    config = Path.join(root, "config.toml")
    File.write!(config, "")
    previous_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      (previous_paths || [])
      |> Keyword.put(:global_config, config)
      |> Keyword.put(:home_state_dir, root)
    )

    on_exit(fn ->
      if is_nil(previous_paths) do
        Application.delete_env(:lemon_core, :paths)
      else
        Application.put_env(:lemon_core, :paths, previous_paths)
      end
    end)

    :ok
  end

  defmodule RouterOk do
    @moduledoc false

    def submit(params) do
      send(self(), {:router_submit, params})
      {:ok, params.run_id}
    end
  end

  defmodule RouterError do
    @moduledoc false

    def submit(_params), do: {:error, :busy}
  end

  defmodule RouterUnexpected do
    @moduledoc false

    def submit(_params), do: :wat
  end

  defmodule RouterRaise do
    @moduledoc false

    def submit(_params), do: raise("boom")
  end

  defmodule RouterExit do
    @moduledoc false

    def submit(_params), do: exit(:nope)
  end

  defmodule Waiter do
    @moduledoc false

    def wait_already_subscribed(run_id, timeout_ms, _opts) do
      send(self(), {:wait_called, run_id, timeout_ms})
      {:ok, "done"}
    end
  end

  defmodule TimeoutWaiter do
    def wait_already_subscribed(_run_id, _timeout_ms, _opts), do: :timeout
  end

  defmodule StubContext do
    @moduledoc false

    def augment_prompt(job, prompt) do
      send(self(), {:augment_prompt_called, job.id, prompt})
      "CHAINED-CONTEXT-BLOCK\n\n" <> prompt
    end
  end

  defp sample_job(attrs \\ %{}) do
    memory_file =
      LemonCore.Paths.home_path([
        "lemon_cron_memory_run_submitter_#{System.unique_integer([:positive])}.md"
      ])

    base = %{
      id: "cron_1",
      name: "Test job",
      schedule: "* * * * *",
      agent_id: "agent_1",
      session_key: "agent:agent_1:main",
      prompt: "hello",
      timeout_ms: 42_000,
      memory_file: memory_file
    }

    CronJob.new(Map.merge(base, attrs))
  end

  defp sample_run(attrs \\ %{}) do
    run = CronRun.new("cron_1", :manual)
    struct!(run, attrs)
  end

  test "build_params/2 maps job and run metadata" do
    job =
      sample_job(%{
        id: "cron_build",
        agent_id: "agent_build",
        session_key: "agent:build:main"
      })

    run = sample_run(%{id: "run_build", triggered_by: :schedule})

    assert %{
             origin: :cron,
             prompt: _prompt,
             agent_id: "agent_build",
             tool_policy: %{blocked_tools: ["cron"]},
             meta: %{
               cron_job_id: "cron_build",
               cron_run_id: "run_build",
               triggered_by: :schedule,
               cron_base_session_key: "agent:build:main",
               cron_memory_file: memory_file
             }
           } = RunSubmitter.build_params(job, run)

    assert memory_file == job.memory_file
  end

  test "build_params/2 forks the session key for each run" do
    job = sample_job(%{session_key: "agent:forked:main", agent_id: "forked"})
    run = sample_run(%{id: "run_1"})

    params1 = RunSubmitter.build_params(job, run)
    params2 = RunSubmitter.build_params(job, run)

    assert params1.session_key != "agent:forked:main"
    assert params1.session_key != params2.session_key
    assert String.starts_with?(params1.session_key, "agent:forked:main:sub:cron_")
    assert SessionKey.valid?(params1.session_key)
  end

  test "submit/3 delegates to router then waiter on success" do
    job = sample_job()
    run = sample_run(%{id: "run_submit", triggered_by: :manual})

    assert {:ok, "done"} =
             RunSubmitter.submit(
               job,
               run,
               router_mod: RouterOk,
               waiter_mod: Waiter
             )

    assert_receive {:router_submit, params}
    submitted_run_id = params.run_id
    assert params.meta.cron_run_id == "run_submit"
    assert params.session_key != job.session_key
    assert SessionKey.valid?(params.session_key)
    assert_receive {:wait_called, ^submitted_run_id, 42_000}

    assert {:ok, memory_text} = File.read(job.memory_file)
    assert memory_text =~ "## Run run_submit"
    assert memory_text =~ "done"
  end

  test "submit/3 returns inspected router error" do
    job = sample_job()
    run = sample_run()

    assert {:error, ":busy"} =
             RunSubmitter.submit(job, run, router_mod: RouterError, waiter_mod: Waiter)

    assert {:ok, memory_text} = File.read(job.memory_file)
    assert memory_text =~ "status: failed"
  end

  test "submit/3 retains ownership for an unexpected router return" do
    job = sample_job()
    run = sample_run(%{run_id: "fixed_unexpected"})

    assert {:error, {:outcome_unknown, "fixed_unexpected"}} =
             RunSubmitter.submit(job, run, router_mod: RouterUnexpected, waiter_mod: Waiter)

    refute File.exists?(job.memory_file)
  end

  test "submit/3 reconciles an exception from the router as outcome unknown" do
    job = sample_job()
    run = sample_run()

    assert {:ok, "done"} =
             RunSubmitter.submit(job, run, router_mod: RouterRaise, waiter_mod: Waiter)
  end

  test "submit/3 reconciles an exit from the router as outcome unknown" do
    job = sample_job()
    run = sample_run()

    assert {:ok, "done"} =
             RunSubmitter.submit(job, run, router_mod: RouterExit, waiter_mod: Waiter)
  end

  test "prompt jobs carry their repository through the native router request" do
    job = sample_job(%{cwd: "/tmp/cron-target"})
    run = sample_run(%{run_id: "fixed_cron_router"})

    assert {:ok, "done"} =
             RunSubmitter.submit(job, run, router_mod: RouterOk, waiter_mod: Waiter)

    assert_receive {:router_submit, %{cwd: "/tmp/cron-target", run_id: "fixed_cron_router"}}
  end

  test "accepted wait timeout retains the fixed run id without writing failed memory" do
    job = sample_job()
    run = sample_run(%{run_id: "fixed_timeout"})

    assert {:error, {:outcome_unknown, "fixed_timeout"}} =
             RunSubmitter.submit(job, run, router_mod: RouterOk, waiter_mod: TimeoutWaiter)

    refute File.exists?(job.memory_file)
  end

  test "ambiguous router submission retains ownership when no completion arrives" do
    job = sample_job()
    run = sample_run(%{run_id: "fixed_ambiguous"})

    assert {:error, {:outcome_unknown, "fixed_ambiguous"}} =
             RunSubmitter.submit(job, run, router_mod: RouterExit, waiter_mod: TimeoutWaiter)

    refute File.exists?(job.memory_file)
  end

  test "rejected ownership claim prevents router submission" do
    assert {:error, _} =
             RunSubmitter.submit(sample_job(), sample_run(),
               router_mod: RouterOk,
               waiter_mod: Waiter,
               on_submitting: fn _id, _session -> {:error, :aborted} end
             )

    refute_receive {:router_submit, _}
  end

  test "profile is resolved at run time with its current node and persona" do
    assert {:ok, profile} =
             LemonCore.ProfileStore.create(%{
               id: "cron-profile",
               node: "worker-old",
               model: "old-model",
               systemPrompt: "Old persona",
               mcpServers: [
                 %{
                   "name" => "bot",
                   "url" => "https://example.com/mcp",
                   "headers" => %{"Authorization" => "Bearer cron-private-token"}
                 }
               ]
             })

    job = sample_job(%{profile_id: "cron-profile", deliver_to: "none"})
    run = sample_run(%{run_id: "fixed_profile_run"})
    old = RunSubmitter.build_params(job, run, run.run_id)
    assert old.meta.node == "worker-old"

    assert {:ok, _} =
             LemonCore.ProfileStore.update("cron-profile", %{
               node: "worker-current",
               model: "current-model",
               systemPrompt: "Current persona",
               toolPolicy: %{
                 "allow" => "all",
                 "deny" => ["bash"],
                 "require_approval" => ["write"],
                 "approvals" => %{"write" => "always"}
               }
             })

    File.write!(Path.join(profile["paths"]["workspace"], "SOUL.md"), "Current instructions")

    assert {:ok, "done"} =
             RunSubmitter.submit(job, run,
               router_mod: RouterOk,
               waiter_mod: Waiter,
               append_memory: false
             )

    assert_receive {:router_submit, params}
    assert params.run_id == "fixed_profile_run"
    assert params.agent_id == "cron-profile"
    assert params.model == "current-model"
    assert params.meta.node == "worker-current"
    assert params.meta.profile_id == "cron-profile"
    assert params.meta.system_prompt == "Current persona"
    assert params.meta.profile_instructions["SOUL.md"] == "Current instructions"

    assert params.meta.mcp_servers |> hd() |> Map.get("headers") ==
             %{"Authorization" => "Bearer cron-private-token"}

    assert params.meta.cron_job_id == job.id
    assert params.meta.cron_run_id == run.id
    assert params.meta.cron_base_session_key == job.session_key
    assert params.meta.cron_session_key == params.session_key
    assert params.meta.remote_cwd_explicit == false
    assert params.cwd == nil
    assert params.tool_policy.blocked_tools == ["cron"]
    assert params.tool_policy.deny == ["bash"]
    assert params.tool_policy.require_approval == ["write"]
    assert params.tool_policy.approvals["write"] == :always
    assert SessionKey.valid?(params.session_key)
    assert params.session_key != job.session_key
    assert job.deliver_to == "none"
  end

  test "profile placement preserves explicit cron cwd and model pin" do
    assert {:ok, _} =
             LemonCore.ProfileStore.create(%{
               id: "pinned-profile",
               node: "worker-one",
               model: "profile-model"
             })

    job = sample_job(%{profile_id: "pinned-profile", cwd: "/worker/project", model: "cron-model"})
    params = RunSubmitter.build_params(job, sample_run(), "fixed_pin")
    assert params.cwd == "/worker/project"
    assert params.meta.remote_cwd_explicit == true
    assert params.meta.remote_cwd == "/worker/project"
    assert params.model == "cron-model"
    assert params.meta.cron_model_pin == "cron-model"
  end

  test "missing runtime profile fails before router submission" do
    job = sample_job(%{profile_id: "deleted-profile"})

    assert {:error, :unknown_profile} =
             RunSubmitter.submit(job, sample_run(),
               router_mod: RouterOk,
               waiter_mod: Waiter,
               append_memory: false
             )

    refute_receive {:router_submit, _}
  end

  describe "model pinning" do
    test "build_params omits :model when the job has no pin" do
      params = RunSubmitter.build_params(sample_job(), sample_run())

      refute Map.has_key?(params, :model)
      refute Map.has_key?(params.meta, :cron_model_pin)
    end

    test "build_params omits :model for a blank pin" do
      params = RunSubmitter.build_params(sample_job(%{model: "   "}), sample_run())

      refute Map.has_key?(params, :model)
      refute Map.has_key?(params.meta, :cron_model_pin)
    end

    test "build_params forwards a pinned model and records it in meta" do
      params = RunSubmitter.build_params(sample_job(%{model: "model-pinned"}), sample_run())

      assert params.model == "model-pinned"
      assert params.meta.cron_model_pin == "model-pinned"
    end
  end

  describe "chained context" do
    test "build_params runs the prompt through the context module" do
      job = sample_job(%{id: "cron_context", context_from: "cron_source"})
      params = RunSubmitter.build_params(job, sample_run(), nil, context_mod: StubContext)

      assert_receive {:augment_prompt_called, "cron_context", "hello"}
      assert params.prompt =~ "CHAINED-CONTEXT-BLOCK"
      assert params.prompt =~ "hello"
    end

    test "build_params defaults to CronContext, which is a no-op without context_from" do
      params = RunSubmitter.build_params(sample_job(), sample_run())

      refute params.prompt =~ "Chained Context"
      assert params.prompt =~ "hello"
    end
  end
end
