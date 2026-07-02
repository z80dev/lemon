defmodule LemonChannels.MediaStatusMessageTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.MediaStatusMessage
  alias LemonMedia.MediaJobs

  test "renders redacted media status text" do
    tmp_dir = tmp_dir()
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    jobs_dir = Path.join(tmp_dir, "jobs")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(artifacts_dir)
    artifact_path = Path.join(artifacts_dir, "private-image.png")
    File.write!(artifact_path, "fake image")

    assert {:ok, _job} =
             MediaJobs.record(
               %{
                 job_id: "image one",
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

    text = MediaStatusMessage.handle("status", dir: jobs_dir, artifacts_dir: artifacts_dir)

    assert text =~ "Media Status"
    assert text =~ "Jobs: 1"
    assert text =~ "Artifacts: 1 (10 B)"
    assert text =~ "Types: image 1"
    assert text =~ "Statuses: completed 1"
    assert text =~ "Recent: image_one image completed private-image.png (10 B)"
    assert text =~ "Cleanup: 30d, 500 jobs, 250 artifacts"
    assert text =~ "Redaction:"
    refute text =~ "private prompt text"
    refute text =~ artifact_path
    refute text =~ "image-model"
    refute text =~ "openai"
  end

  test "renders empty media status text" do
    tmp_dir = tmp_dir()
    jobs_dir = Path.join(tmp_dir, "jobs")
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    text = MediaStatusMessage.handle(nil, dir: jobs_dir, artifacts_dir: artifacts_dir)

    assert text =~ "Media Status"
    assert text =~ "Jobs: 0"
    assert text =~ "Artifacts: 0 (0 B)"
    assert text =~ "Types: none"
    assert text =~ "Recent: none"
  end

  test "recognizes telegram media command for bot" do
    assert Commands.media_command?("/media", "lemon_bot")
    assert Commands.media_command?("/media status", "lemon_bot")
    assert Commands.media_command?("/media@lemon_bot status", "lemon_bot")
    refute Commands.media_command?("/media@other_bot status", "lemon_bot")
  end

  test "renders media command usage" do
    assert MediaStatusMessage.handle("help") == "Usage: /media status"
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_channels_media_status_test_#{System.unique_integer([:positive])}"
    )
  end
end
