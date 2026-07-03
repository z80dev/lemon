defmodule LemonRouter.MediaJobRecorderTest do
  use ExUnit.Case, async: true

  alias LemonRouter.MediaJobRecorder

  test "records generated final-answer files into redacted media jobs" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(Path.join(tmp_dir, "artifacts"))
    generated = Path.join(tmp_dir, "artifacts/chart.png")
    explicit = Path.join(tmp_dir, "artifacts/notes.txt")
    File.write!(generated, "png")
    File.write!(explicit, "notes")

    state = %{
      run_id: "run_media_1",
      session_key: "agent:secret-session",
      execution_request: %{cwd: tmp_dir, route: %{channel_id: "telegram"}}
    }

    result =
      MediaJobRecorder.record_auto_send_files(
        %{
          auto_send_files: [
            %{path: explicit, filename: "notes.txt", source: :explicit},
            %{
              path: generated,
              filename: "chart.png",
              caption: "private caption",
              source: :generated,
              mime_type: "image/png"
            }
          ]
        },
        state,
        project_dir: tmp_dir,
        created_at: "2026-05-16T12:00:00Z"
      )

    assert result == %{recorded_count: 1, skipped_count: 1, failed_count: 0}

    assert [job] = LemonMedia.MediaJobs.recent(project_dir: tmp_dir)
    assert job.type == :image
    assert job.status == :completed
    assert job.channel == "telegram"
    assert job.artifact.name == "chart.png"
    assert job.artifact.bytes == 3
    assert is_binary(job.artifact.path_hash)
    refute inspect(job) =~ generated
    refute inspect(job) =~ explicit
    refute inspect(job) =~ "private caption"
    refute inspect(job) =~ "secret-session"
  end

  test "skips missing, explicit, and non-file entries" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    result =
      MediaJobRecorder.record_auto_send_files(
        %{
          auto_send_files: [
            %{path: Path.join(tmp_dir, "missing.png"), source: :generated},
            %{path: "", source: :generated},
            %{path: Path.join(tmp_dir, "notes.txt"), source: :explicit},
            %{}
          ]
        },
        %{run_id: "run_media_2", execution_request: %{cwd: tmp_dir}},
        project_dir: tmp_dir
      )

    assert result == %{recorded_count: 0, skipped_count: 4, failed_count: 0}
    assert [] = LemonMedia.MediaJobs.recent(project_dir: tmp_dir)
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_media_job_recorder_test_#{System.unique_integer([:positive])}"
    )
  end
end
