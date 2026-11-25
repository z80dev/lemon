defmodule LemonMedia.MediaJobSupervisorTest do
  use ExUnit.Case, async: false

  alias LemonMedia.MediaJobSupervisor
  alias LemonMedia.MediaJobs

  test "runs a media job to completion with redacted metadata" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    parent = self()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(artifacts_dir)

    runner = fn attrs ->
      artifact_path = Path.join(artifacts_dir, "#{attrs.job_id}.png")
      File.write!(artifact_path, "fake image")
      send(parent, {:runner_attrs, attrs})
      {:ok, %{artifact_path: artifact_path, mime_type: "image/png"}}
    end

    assert {:ok, completed_job} =
             MediaJobSupervisor.run_job(
               %{
                 job_id: "beam image",
                 type: :image,
                 provider: "openai",
                 model: "gpt-image",
                 channel: "discord",
                 prompt: "private prompt text",
                 created_at: "2026-05-16T14:00:00Z"
               },
               dir: jobs_dir,
               artifacts_dir: artifacts_dir,
               runner: runner,
               timeout_ms: 5_000
             )

    assert_receive {:runner_attrs, %{job_id: "beam_image", status: :running}}
    assert completed_job.job_id == "beam_image"
    assert completed_job.status == :completed
    assert completed_job.artifact.name == "beam_image.png"
    assert completed_job.artifact.bytes == 10
    refute inspect(completed_job) =~ "private prompt text"
    refute inspect(completed_job) =~ artifacts_dir

    [recent] = MediaJobs.recent(dir: jobs_dir)
    assert recent.status == :completed
    refute inspect(recent) =~ "private prompt text"
  end

  test "records runner failure without storing raw error details" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    runner = fn _attrs -> {:error, {:provider_failed, "secret provider response"}} end

    assert {:error, {:failed, failed_job}} =
             MediaJobSupervisor.run_job(
               %{job_id: "failed image", type: :image, prompt: "private prompt text"},
               dir: jobs_dir,
               runner: runner,
               timeout_ms: 5_000
             )

    assert failed_job.status == :failed
    assert failed_job.error_kind == "provider_failed"
    assert is_binary(failed_job.error_hash)
    refute inspect(failed_job) =~ "secret provider response"
    refute inspect(failed_job) =~ "private prompt text"

    [recent] = MediaJobs.recent(dir: jobs_dir)
    assert recent.status == :failed
    refute inspect(recent) =~ "secret provider response"
  end

  test "records safe provider failure details without raw response text" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    runner = fn _attrs ->
      {:error, {:provider_failed, 400, {:safe_error_kind, "Invalid Request Error"}}}
    end

    assert {:error, {:failed, failed_job}} =
             MediaJobSupervisor.run_job(%{job_id: "failed detail", type: :image},
               dir: jobs_dir,
               runner: runner,
               timeout_ms: 5_000
             )

    assert failed_job.error_kind == "provider_failed:invalid_request_error"
  end

  test "a timed-out job is killed and recorded cancelled, never left running" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    parent = self()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    runner = fn _attrs ->
      send(parent, {:runner_started, self()})
      Process.sleep(:infinity)
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, {:cancelled, :timeout, job}} =
             MediaJobSupervisor.run_job(%{job_id: "slow image", type: :image},
               dir: jobs_dir,
               runner: runner,
               timeout_ms: 200
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 200 and elapsed < 1_000
    assert_receive {:runner_started, runner_pid}
    refute Process.alive?(runner_pid)
    assert job.status == :cancelled
    assert [%{status: :cancelled, error_kind: "timeout"}] = MediaJobs.recent(dir: jobs_dir)
    assert MediaJobSupervisor.status().active_jobs == 0
  end

  test "unrelated mailbox traffic neither extends the deadline nor is consumed" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    parent = self()

    noise =
      spawn(fn ->
        for n <- 1..100 do
          send(parent, {:media_job, :running, %{job_id: "other-#{n}"}})
          Process.sleep(5)
        end
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, {:cancelled, :timeout, _job}} =
             MediaJobSupervisor.run_job(%{job_id: "noisy", type: :image},
               dir: jobs_dir,
               runner: fn _attrs -> Process.sleep(:infinity) end,
               timeout_ms: 300
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
    Process.exit(noise, :kill)
    assert_received {:media_job, :running, %{job_id: "other-1"}}
  end

  test "abort kills the job and records it cancelled" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    parent = self()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    flag = :atomics.new(1, [])

    runner = fn _attrs ->
      send(parent, {:runner_started, self()})
      :atomics.put(flag, 1, 1)
      Process.sleep(:infinity)
    end

    assert {:error, {:cancelled, :aborted, _job}} =
             MediaJobSupervisor.run_job(%{job_id: "aborted", type: :image},
               dir: jobs_dir,
               runner: runner,
               timeout_ms: 5_000,
               aborted?: fn -> :atomics.get(flag, 1) == 1 end
             )

    assert_receive {:runner_started, runner_pid}
    refute Process.alive?(runner_pid)
    assert [%{status: :cancelled, error_kind: "aborted"}] = MediaJobs.recent(dir: jobs_dir)
  end

  test "a job never outlives a caller that is killed mid-wait" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    parent = self()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    caller =
      spawn(fn ->
        MediaJobSupervisor.run_job(%{job_id: "orphan", type: :image},
          dir: jobs_dir,
          runner: fn _attrs ->
            send(parent, {:runner_started, self()})
            Process.sleep(:infinity)
          end,
          timeout_ms: 60_000
        )
      end)

    assert_receive {:runner_started, runner_pid}, 1_000
    runner_ref = Process.monitor(runner_pid)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :killed}, 1_000

    assert_eventually(fn ->
      match?(
        [%{status: :cancelled, error_kind: "caller_exited"}],
        MediaJobs.recent(dir: jobs_dir)
      )
    end)
  end

  test "a job killed underneath the caller is recorded failed, not running" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    killer =
      spawn(fn ->
        receive do
          {:runner_started, pid} -> Process.exit(pid, :kill)
        end
      end)

    assert {:error, {:failed, job}} =
             MediaJobSupervisor.run_job(%{job_id: "killed", type: :image},
               dir: jobs_dir,
               runner: fn _attrs ->
                 send(killer, {:runner_started, self()})
                 Process.sleep(:infinity)
               end,
               timeout_ms: 5_000
             )

    assert job.error_kind == "job_exited"
    assert [%{status: :failed, error_kind: "job_exited"}] = MediaJobs.recent(dir: jobs_dir)
  end

  test "capacity rejection records failure without running or retrying the job" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    parent = self()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    original_supervisor = Process.whereis(MediaJobSupervisor)
    true = Process.unregister(MediaJobSupervisor)

    try do
      supervisor = start_supervised!({MediaJobSupervisor, max_children: 1})

      assert {:ok, blocker} =
               LemonCore.TaskSupervisor.start_child(supervisor, fn ->
                 receive do
                   :finish -> :ok
                 end
               end)

      runner = fn attrs ->
        send(parent, {:admitted_media_job, attrs.job_id})
        {:ok, %{}}
      end

      assert {:error, :task_capacity_reached} =
               MediaJobSupervisor.run_job(%{job_id: "over-capacity", type: :image},
                 dir: jobs_dir,
                 runner: runner,
                 timeout_ms: 1_000
               )

      assert [%{status: :failed, error_kind: "task_capacity_reached"}] =
               MediaJobs.recent(dir: jobs_dir)

      refute_received {:admitted_media_job, _}

      :ok = Task.Supervisor.terminate_child(supervisor, blocker)

      assert {:ok, %{job_id: "after-capacity"}} =
               MediaJobSupervisor.run_job(%{job_id: "after-capacity", type: :image},
                 dir: jobs_dir,
                 runner: runner,
                 timeout_ms: 1_000
               )

      assert_received {:admitted_media_job, "after-capacity"}
      refute_received {:admitted_media_job, "over-capacity"}
    after
      stop_supervised(MediaJobSupervisor)
      true = Process.register(original_supervisor, MediaJobSupervisor)
    end
  end

  test "unavailable supervisor records admission failure without running the job" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    parent = self()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    supervisor = Process.whereis(MediaJobSupervisor)
    true = Process.unregister(MediaJobSupervisor)

    try do
      assert {:error, :task_supervisor_unavailable} =
               MediaJobSupervisor.run_job(%{job_id: "unavailable", type: :image},
                 dir: jobs_dir,
                 runner: fn _attrs ->
                   send(parent, :unavailable_job_ran)
                   {:ok, %{}}
                 end,
                 timeout_ms: 1_000
               )

      assert [%{status: :failed, error_kind: "task_supervisor_unavailable"}] =
               MediaJobs.recent(dir: jobs_dir)

      refute_received :unavailable_job_ran
      assert MediaJobSupervisor.status() == %{running: false, active_jobs: 0}
    after
      true = Process.register(supervisor, MediaJobSupervisor)
    end
  end

  defp assert_eventually(fun, attempts \\ 300)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_media_job_supervisor_test_#{System.unique_integer([:positive])}"
    )
  end
end
