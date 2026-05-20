defmodule LemonCore.MediaJobSupervisorTest do
  use ExUnit.Case, async: false

  alias LemonCore.MediaJobSupervisor
  alias LemonCore.MediaJobs

  test "runs a media worker to completion with redacted metadata and events" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    parent = self()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(artifacts_dir)
    Phoenix.PubSub.subscribe(LemonCore.PubSub, "media_jobs")

    runner = fn attrs ->
      artifact_path = Path.join(artifacts_dir, "#{attrs.job_id}.png")
      File.write!(artifact_path, "fake image")
      send(parent, {:runner_attrs, attrs})
      {:ok, %{artifact_path: artifact_path, mime_type: "image/png"}}
    end

    assert {:ok, _pid, queued_job} =
             MediaJobSupervisor.start_job(
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
               runner: runner
             )

    assert queued_job.status == :queued
    assert queued_job.job_id == "beam_image"
    assert_receive {:media_job, :running, %{job_id: "beam_image", status: :running}}
    assert_receive {:runner_attrs, %{job_id: "beam_image", status: :running}}
    assert_receive {:media_job, :completed, completed_job}

    assert completed_job.status == :completed
    assert completed_job.artifact.name == "beam_image.png"
    assert completed_job.artifact.bytes == 10
    refute inspect(completed_job) =~ "private prompt text"
    refute inspect(completed_job) =~ artifacts_dir

    [recent] = MediaJobs.recent(dir: jobs_dir)
    assert recent.status == :completed
    assert recent.artifact.name == "beam_image.png"
    refute inspect(recent) =~ "private prompt text"
    refute inspect(recent) =~ artifacts_dir
  end

  test "records worker failure without storing raw error details" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    parent = self()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Phoenix.PubSub.subscribe(LemonCore.PubSub, "media_jobs")

    runner = fn attrs ->
      send(parent, {:failed_runner_attrs, attrs})
      {:error, {:provider_failed, "secret provider response"}}
    end

    assert {:ok, _pid, _queued_job} =
             MediaJobSupervisor.start_job(
               %{
                 job_id: "failed image",
                 type: :image,
                 provider: "openai",
                 prompt: "private prompt text"
               },
               dir: jobs_dir,
               runner: runner
             )

    assert_receive {:media_job, :running, %{job_id: "failed_image", status: :running}}
    assert_receive {:failed_runner_attrs, %{job_id: "failed_image", status: :running}}
    assert_receive {:media_job, :failed, failed_job}

    assert failed_job.status == :failed
    assert failed_job.error_kind == "provider_failed"
    assert is_binary(failed_job.error_hash)
    refute inspect(failed_job) =~ "secret provider response"
    refute inspect(failed_job) =~ "private prompt text"

    [recent] = MediaJobs.recent(dir: jobs_dir)
    assert recent.status == :failed
    assert recent.error_kind == "provider_failed"
    refute inspect(recent) =~ "secret provider response"
  end

  test "records safe provider failure details without raw response text" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Phoenix.PubSub.subscribe(LemonCore.PubSub, "media_jobs")

    runner = fn _attrs ->
      {:error, {:provider_failed, 400, {:safe_error_kind, "Invalid Request Error"}}}
    end

    assert {:ok, _pid, _queued_job} =
             MediaJobSupervisor.start_job(
               %{
                 job_id: "failed detail image",
                 type: :image,
                 provider: "openai",
                 prompt: "private prompt text"
               },
               dir: jobs_dir,
               runner: runner
             )

    assert_receive {:media_job, :running, %{job_id: "failed_detail_image", status: :running}}
    assert_receive {:media_job, :failed, failed_job}

    assert failed_job.status == :failed
    assert failed_job.error_kind == "provider_failed:invalid_request_error"
    assert is_binary(failed_job.error_hash)
    refute inspect(failed_job) =~ "private prompt text"

    [recent] = MediaJobs.recent(dir: jobs_dir)
    assert recent.error_kind == "provider_failed:invalid_request_error"
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_media_job_supervisor_test_#{System.unique_integer([:positive])}"
    )
  end
end
