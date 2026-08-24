defmodule LemonAutomation.CronMonitorTest do
  # async: false — CronMonitor persists fingerprints in the shared LemonCore.Store.
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronMonitor, CronRun, CronStore}

  setup do
    token = System.unique_integer([:positive, :monotonic])
    job_id = "cron_monitor_#{token}"

    on_exit(fn ->
      CronStore.delete_monitor_state(job_id)

      for event <- CronStore.list_audit_events(job_id: job_id, limit: 200) do
        CronStore.delete_audit_event(event.id)
      end
    end)

    {:ok, token: token, job_id: job_id}
  end

  describe "normalize/1" do
    test "nil becomes an empty string" do
      assert CronMonitor.normalize(nil) == ""
    end

    test "CRLF, trailing spaces and surrounding blank lines hash the same" do
      canonical = "alpha\nbeta"

      variants = [
        "alpha\r\nbeta",
        "alpha   \nbeta   ",
        "\n\nalpha\nbeta\n\n",
        "  \r\nalpha\t\r\nbeta\r\n  "
      ]

      expected = CronMonitor.hash(canonical)

      for variant <- variants do
        assert CronMonitor.hash(variant) == expected, "expected #{inspect(variant)} to normalize"
      end
    end

    test "interior indentation is content, not noise" do
      # Only trailing whitespace and the surrounding blank lines are normalized
      # away; leading indentation inside the body still counts.
      refute CronMonitor.hash("alpha\n  beta") == CronMonitor.hash("alpha\nbeta")
    end

    test "semantically different text hashes differently" do
      refute CronMonitor.hash("alpha") == CronMonitor.hash("beta")
    end

    test "hash/1 is a lowercase hex sha256" do
      digest = CronMonitor.hash("alpha")
      assert String.length(digest) == 64
      assert digest == String.downcase(digest)
      assert digest =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "monitor?/1" do
    test "true only for jobs with monitor: true", %{job_id: job_id} do
      assert CronMonitor.monitor?(job(job_id, monitor: true))
      refute CronMonitor.monitor?(job(job_id, monitor: false))
      refute CronMonitor.monitor?(nil)
    end
  end

  describe "apply_policy/2" do
    test "nil job delivers", %{job_id: job_id} do
      run = completed_run(job_id, "same")
      assert {^run, true} = CronMonitor.apply_policy(nil, run)
    end

    test "non-monitor job delivers and records no state", %{job_id: job_id} do
      run = completed_run(job_id, "same")

      assert {^run, true} = CronMonitor.apply_policy(job(job_id, monitor: false), run)
      assert CronStore.get_monitor_state(job_id) == nil
    end

    test "first run delivers and records a baseline when notify_first_run is true", %{
      job_id: job_id
    } do
      job = job(job_id, monitor: true, monitor_notify_first_run: true)
      run = completed_run(job_id, "hello")

      assert {result_run, true} = CronMonitor.apply_policy(job, run)
      refute result_run.suppressed

      state = CronStore.get_monitor_state(job_id)
      assert state.last_hash == CronMonitor.hash("hello")
      assert state.last_run_id == run.id
      assert state.runs_since_change == 0

      assert audit_actions(job_id) |> Enum.member?("monitor_baseline_recorded")
    end

    test "first run is suppressed when notify_first_run is false", %{job_id: job_id} do
      job = job(job_id, monitor: true, monitor_notify_first_run: false)
      run = completed_run(job_id, "hello")

      assert {result_run, false} = CronMonitor.apply_policy(job, run)
      assert result_run.suppressed == true
      assert CronStore.get_monitor_state(job_id).last_hash == CronMonitor.hash("hello")
    end

    test "unchanged scheduled run is suppressed and bumps runs_since_change", %{job_id: job_id} do
      job = job(job_id, monitor: true)

      assert {_run, true} = CronMonitor.apply_policy(job, completed_run(job_id, "hello"))

      second = completed_run(job_id, "hello\n")
      assert {result_run, false} = CronMonitor.apply_policy(job, second)
      assert result_run.suppressed == true

      state = CronStore.get_monitor_state(job_id)
      assert state.runs_since_change == 1
      assert state.last_run_id == second.id

      third = completed_run(job_id, "hello")
      assert {_run, false} = CronMonitor.apply_policy(job, third)
      assert CronStore.get_monitor_state(job_id).runs_since_change == 2

      assert "monitor_output_unchanged" in audit_actions(job_id)
    end

    test "changed run delivers, resets the counter and audits the change", %{job_id: job_id} do
      job = job(job_id, monitor: true)

      assert {_run, true} = CronMonitor.apply_policy(job, completed_run(job_id, "hello"))
      assert {_run, false} = CronMonitor.apply_policy(job, completed_run(job_id, "hello"))

      changed = completed_run(job_id, "goodbye")
      assert {result_run, true} = CronMonitor.apply_policy(job, changed)
      refute result_run.suppressed

      state = CronStore.get_monitor_state(job_id)
      assert state.last_hash == CronMonitor.hash("goodbye")
      assert state.runs_since_change == 0
      assert state.last_run_id == changed.id

      assert "monitor_output_changed" in audit_actions(job_id)
    end

    test "failed and timeout runs always deliver and leave state untouched", %{job_id: job_id} do
      job = job(job_id, monitor: true)

      assert {_run, true} = CronMonitor.apply_policy(job, completed_run(job_id, "hello"))
      baseline = CronStore.get_monitor_state(job_id)

      failed = %{completed_run(job_id, nil) | status: :failed, error: "boom"}
      assert {^failed, true} = CronMonitor.apply_policy(job, failed)

      timed_out = %{completed_run(job_id, nil) | status: :timeout}
      assert {^timed_out, true} = CronMonitor.apply_policy(job, timed_out)

      aborted = %{completed_run(job_id, nil) | status: :aborted}
      assert {^aborted, true} = CronMonitor.apply_policy(job, aborted)

      assert CronStore.get_monitor_state(job_id) == baseline

      # Recovery to the pre-failure output is still suppressed.
      assert {recovered, false} = CronMonitor.apply_policy(job, completed_run(job_id, "hello"))
      assert recovered.suppressed == true
    end

    test "manual and wake runs deliver even when unchanged", %{job_id: job_id} do
      job = job(job_id, monitor: true)

      assert {_run, true} = CronMonitor.apply_policy(job, completed_run(job_id, "hello"))
      before = CronStore.get_monitor_state(job_id)

      manual = %{completed_run(job_id, "hello") | triggered_by: :manual}
      assert {result_run, true} = CronMonitor.apply_policy(job, manual)
      refute result_run.suppressed
      # unchanged manual runs do not re-audit or mutate state
      assert CronStore.get_monitor_state(job_id) == before

      wake = %{completed_run(job_id, "hello") | triggered_by: :wake}
      assert {_run, true} = CronMonitor.apply_policy(job, wake)
    end

    test "manual run with changed output delivers and updates state", %{job_id: job_id} do
      job = job(job_id, monitor: true)

      assert {_run, true} = CronMonitor.apply_policy(job, completed_run(job_id, "hello"))

      manual = %{completed_run(job_id, "different") | triggered_by: :manual}
      assert {_run, true} = CronMonitor.apply_policy(job, manual)

      assert CronStore.get_monitor_state(job_id).last_hash == CronMonitor.hash("different")
    end

    test "manual first run delivers even when notify_first_run is false", %{job_id: job_id} do
      job = job(job_id, monitor: true, monitor_notify_first_run: false)
      manual = %{completed_run(job_id, "hello") | triggered_by: :manual}

      assert {result_run, true} = CronMonitor.apply_policy(job, manual)
      refute result_run.suppressed
    end

    test "store failures fail open", %{job_id: job_id} do
      # A non-binary job id makes the CronStore guards raise inside apply_policy.
      job = %{job(job_id, monitor: true) | id: :not_a_binary}
      run = completed_run(job_id, "hello")

      assert {^run, true} = CronMonitor.apply_policy(job, run)
    end
  end

  defp job(job_id, attrs) do
    %CronJob{
      id: job_id,
      name: "Monitor Job",
      schedule: "* * * * *",
      agent_id: "agent_monitor",
      session_key: "agent:agent_monitor:main",
      prompt: "watch something"
    }
    |> struct!(Map.new(attrs))
  end

  defp completed_run(job_id, output) do
    %CronRun{
      id: "run_monitor_#{System.unique_integer([:positive, :monotonic])}",
      job_id: job_id,
      run_id: "router_monitor",
      status: :completed,
      started_at_ms: 1_000,
      completed_at_ms: 1_010,
      duration_ms: 10,
      triggered_by: :schedule,
      output: output,
      suppressed: false,
      meta: %{}
    }
  end

  defp audit_actions(job_id) do
    CronStore.list_audit_events(job_id: job_id, limit: 100)
    |> Enum.map(& &1.action)
  end
end
