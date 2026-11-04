defmodule LemonAutomation.HeartbeatTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronRun, Heartbeat}

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
