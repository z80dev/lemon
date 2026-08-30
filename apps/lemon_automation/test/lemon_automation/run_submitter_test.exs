defmodule LemonAutomation.RunSubmitterTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.{CronJob, CronRun, RunSubmitter}
  alias LemonCore.SessionKey

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

  defmodule StubContext do
    @moduledoc false

    def augment_prompt(job, prompt) do
      send(self(), {:augment_prompt_called, job.id, prompt})
      "CHAINED-CONTEXT-BLOCK\n\n" <> prompt
    end
  end

  defp sample_job(attrs \\ %{}) do
    memory_file =
      Path.join(
        System.tmp_dir!(),
        "lemon_cron_memory_run_submitter_#{System.unique_integer([:positive])}.md"
      )

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
             prompt: prompt,
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

    assert String.starts_with?(prompt, "You are running a scheduled cron task.")
    assert prompt =~ "isolated forked session"
    assert prompt =~ "Use the memory notes below as prior run history"

    assert prompt =~
             "the scheduler forwards your concise completion summary back to the originating session"

    assert prompt =~
             "do not create, update, remove, or recursively schedule cron jobs from this run"

    assert String.contains?(prompt, "## Task")
    assert is_binary(memory_file)
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

  test "submit/3 returns descriptive error for unexpected router return" do
    job = sample_job()
    run = sample_run()

    assert {:error, msg} =
             RunSubmitter.submit(job, run, router_mod: RouterUnexpected, waiter_mod: Waiter)

    assert msg =~ "Unexpected submit result"
  end

  test "submit/3 rescues exceptions from router" do
    job = sample_job()
    run = sample_run()

    assert {:error, "boom"} =
             RunSubmitter.submit(job, run, router_mod: RouterRaise, waiter_mod: Waiter)
  end

  test "submit/3 catches exits from router" do
    job = sample_job()
    run = sample_run()

    assert {:error, "Exit: :nope"} =
             RunSubmitter.submit(job, run, router_mod: RouterExit, waiter_mod: Waiter)
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
      assert params.prompt =~ "## Task"
      assert params.prompt =~ "hello"
    end

    test "build_params defaults to CronContext, which is a no-op without context_from" do
      params = RunSubmitter.build_params(sample_job(), sample_run())

      refute params.prompt =~ "Chained Context"
      assert params.prompt =~ "hello"
    end
  end
end
