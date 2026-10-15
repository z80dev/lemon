defmodule LemonAutomation.HeartbeatTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronRun, Heartbeat}

  defmodule FakeCron do
    @moduledoc false
    use Agent

    def start_link(jobs), do: Agent.start_link(fn -> jobs end, name: __MODULE__)
    def list, do: Agent.get(__MODULE__, & &1)

    def add_new(params) do
      job = CronJob.new(params)
      Agent.update(__MODULE__, &[job | &1])
      {:ok, job}
    end

    def update(id, patch) do
      Agent.get_and_update(__MODULE__, fn jobs ->
        jobs = Enum.map(jobs, &if(&1.id == id, do: CronJob.update(&1, patch), else: &1))
        {{:ok, Enum.find(jobs, &(&1.id == id))}, jobs}
      end)
    end

    def remove(id) do
      Agent.update(__MODULE__, fn jobs -> Enum.reject(jobs, &(&1.id == id)) end)
    end
  end

  describe "apply_policy/2" do
    test "suppresses an all-clear heartbeat and delivers everything else" do
      heartbeat = job(meta: %{"heartbeat" => true})

      {ok_run, deliver?} = Heartbeat.apply_policy(heartbeat, run(:completed, "\nHEARTBEAT_OK "))
      assert ok_run.suppressed
      refute deliver?

      {alert, deliver?} =
        Heartbeat.apply_policy(heartbeat, run(:completed, "HEARTBEAT_OK - disk 95%"))

      refute alert.suppressed
      assert deliver?

      assert {%CronRun{suppressed: false}, true} =
               Heartbeat.apply_policy(heartbeat, run(:failed, "HEARTBEAT_OK"))
    end

    test "ordinary jobs do not recognize HEARTBEAT_OK" do
      assert {%CronRun{suppressed: false}, true} =
               Heartbeat.apply_policy(job(meta: %{}), run(:completed, "HEARTBEAT_OK"))

      assert {%CronRun{suppressed: false}, true} =
               Heartbeat.apply_policy(nil, run(:completed, "HEARTBEAT_OK"))
    end

    test "only successful prompt jobs recognize an exact SILENT marker" do
      prompt_job = job(meta: %{})

      assert {%CronRun{suppressed: true}, false} =
               Heartbeat.apply_policy(prompt_job, run(:completed, " \n[SILENT]\t"))

      for status <- [:failed, :timeout, :aborted] do
        assert {%CronRun{suppressed: false}, true} =
                 Heartbeat.apply_policy(prompt_job, run(status, "[SILENT]"))
      end

      assert {%CronRun{suppressed: false}, true} =
               Heartbeat.apply_policy(prompt_job, run(:completed, "[SILENT] but important"))

      assert {%CronRun{suppressed: false}, true} =
               Heartbeat.apply_policy(
                 job(command: "echo", prompt: nil),
                 run(:completed, "[SILENT]")
               )
    end
  end

  describe "sync_daily_brief/2" do
    setup do
      start_supervised!({FakeCron, []})
      :ok
    end

    test "creates, reschedules, and removes the daily brief heartbeat" do
      assert :ok = Heartbeat.sync_daily_brief("07:45", cron_manager: FakeCron)

      assert [%CronJob{} = job] = FakeCron.list()
      assert job.id == Heartbeat.daily_brief_id()
      assert job.schedule == "45 7 * * *"
      assert job.timezone == "local"
      assert job.session_key == "agent:default:main"
      assert Heartbeat.heartbeat?(job)

      assert :ok = Heartbeat.sync_daily_brief("07:45", cron_manager: FakeCron)
      assert [^job] = FakeCron.list()

      assert :ok = Heartbeat.sync_daily_brief("9:05", cron_manager: FakeCron)
      assert [%CronJob{schedule: "5 9 * * *", enabled: true}] = FakeCron.list()

      assert :ok = Heartbeat.sync_daily_brief(nil, cron_manager: FakeCron)
      assert [] = FakeCron.list()
    end

    test "an invalid time leaves existing jobs untouched" do
      assert {:error, :invalid_time} = Heartbeat.sync_daily_brief("8am", cron_manager: FakeCron)
      assert [] = FakeCron.list()
    end
  end

  defp job(attrs) do
    CronJob.new(
      Map.merge(
        %{name: "hb", schedule: "*/30 * * * *", agent_id: "default", prompt: "check"},
        Map.new(attrs)
      )
    )
  end

  defp run(status, output) do
    %CronRun{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: "job",
      status: status,
      output: output
    }
  end
end
