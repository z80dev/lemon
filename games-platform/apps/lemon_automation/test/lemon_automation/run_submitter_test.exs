defmodule LemonAutomation.RunSubmitterTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.{CronJob, CronRun, RunSubmitter}
  alias LemonCore.SessionKey

  defmodule RouterOk do
    @moduledoc false

    def submit(params) do
      send(self(), {:router_submit, params})
      {:ok, "run_ok"}
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

    def wait(run_id, timeout_ms, _opts) do
      send(self(), {:wait_called, run_id, timeout_ms})
      {:ok, "done"}
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
             meta: %{
               cron_job_id: "cron_build",
               cron_run_id: "run_build",
               triggered_by: :schedule,
               cron_base_session_key: "agent:build:main",
               cron_memory_file: memory_file
             }
           } = RunSubmitter.build_params(job, run)

    assert String.starts_with?(prompt, "You are running a scheduled cron task.")
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
    assert params.meta.cron_run_id == "run_submit"
    assert params.session_key != job.session_key
    assert SessionKey.valid?(params.session_key)
    assert_receive {:wait_called, "run_ok", 42_000}

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
end
