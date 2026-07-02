defmodule LemonMedia.MediaJobsTest do
  use ExUnit.Case, async: true

  alias LemonMedia.MediaJobs

  test "records media job metadata without storing prompts or raw artifact paths" do
    tmp_dir = tmp_dir()
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(artifacts_dir)
    artifact_path = Path.join(artifacts_dir, "image.png")
    File.write!(artifact_path, "fake image")

    assert {:ok, job} =
             MediaJobs.record(
               %{
                 job_id: "job one",
                 type: :image,
                 status: :completed,
                 provider: "openai",
                 model: "image-model",
                 channel: "telegram",
                 prompt: "private prompt text",
                 artifact_path: artifact_path,
                 mime_type: "image/png",
                 created_at: "2026-05-16T12:00:00Z"
               },
               dir: jobs_dir
             )

    assert job.job_id == "job_one"
    assert job.type == :image
    assert job.status == :completed
    assert job.artifact.name == "image.png"
    assert job.artifact.bytes == 10
    assert job.artifact.exists == true
    assert is_binary(job.prompt_hash)
    assert job.prompt_chars == 19
    refute inspect(job) =~ "private prompt text"
    refute inspect(job) =~ artifact_path

    [recent] = MediaJobs.recent(dir: jobs_dir)
    assert recent.job_id == "job_one"
    assert recent.artifact.name == "image.png"
    assert is_binary(recent.artifact.path_hash)
    refute inspect(recent) =~ "private prompt text"
    refute inspect(recent) =~ artifact_path
  end

  test "summarizes jobs, artifacts, and redaction policy" do
    tmp_dir = tmp_dir()
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(artifacts_dir)
    File.write!(Path.join(artifacts_dir, "one.mp3"), "audio")

    assert {:ok, _job} =
             MediaJobs.record(
               %{
                 job_id: "tts-1",
                 type: :tts,
                 status: :running,
                 channel: "discord",
                 created_at: "2026-05-16T12:00:00Z"
               },
               dir: jobs_dir
             )

    summary = MediaJobs.summary(dir: jobs_dir, artifacts_dir: artifacts_dir)

    assert summary.exists == true
    assert summary.count == 1
    assert summary.status_counts.running == 1
    assert summary.type_counts.tts == 1
    assert summary.artifact_count == 1
    assert summary.artifact_total_bytes == 5
    assert summary.oldest_created_at == "2026-05-16T12:00:00Z"
    assert summary.newest_created_at == "2026-05-16T12:00:00Z"
    assert summary.cleanup.managed == true
    assert summary.cleanup.safe_to_delete == true
    assert summary.cleanup.includes_raw_paths == false
    assert summary.cleanup.includes_prompts == false
    assert summary.cleanup.includes_provider_responses == false
    assert summary.cleanup.includes_channel_message_bodies == false
    assert summary.cleanup.embeds_artifact_bytes_in_support_bundle == false
  end

  test "cleans up old job metadata and media artifacts" do
    tmp_dir = tmp_dir()
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(artifacts_dir)
    old_artifact = Path.join(artifacts_dir, "old.png")
    fresh_artifact = Path.join(artifacts_dir, "fresh.png")
    File.write!(old_artifact, "old")
    File.write!(fresh_artifact, "fresh")
    File.touch!(old_artifact, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(fresh_artifact, {{2026, 1, 10}, {0, 0, 0}})

    assert {:ok, _job} =
             MediaJobs.record(
               %{job_id: "old", status: :completed, created_at: "2026-01-01T00:00:00Z"},
               dir: jobs_dir
             )

    assert {:ok, _job} =
             MediaJobs.record(
               %{job_id: "fresh", status: :completed, created_at: "2026-01-10T00:00:00Z"},
               dir: jobs_dir
             )

    File.touch!(Path.join(jobs_dir, "old.json"), {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(Path.join(jobs_dir, "fresh.json"), {{2026, 1, 10}, {0, 0, 0}})

    now = DateTime.to_unix(~U[2026-01-10 00:00:00Z])

    result =
      MediaJobs.cleanup(
        dir: jobs_dir,
        artifacts_dir: artifacts_dir,
        max_age_seconds: 2 * 24 * 60 * 60,
        now: now
      )

    assert result.deleted_jobs_count == 1
    assert result.deleted_artifacts_count == 1
    assert result.deleted_artifact_bytes == 3
    refute File.exists?(Path.join(jobs_dir, "old.json"))
    assert File.exists?(Path.join(jobs_dir, "fresh.json"))
    refute File.exists?(old_artifact)
    assert File.exists?(fresh_artifact)
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_media_jobs_test_#{System.unique_integer([:positive])}"
    )
  end
end
