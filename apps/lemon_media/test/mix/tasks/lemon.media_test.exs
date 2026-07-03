defmodule Mix.Tasks.Lemon.MediaTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonMedia.MediaJobs
  alias Mix.Tasks.Lemon.Media

  setup do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.start")

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_media_task_test_#{System.unique_integer([:positive])}"
      )

    artifacts_dir = Path.join([tmp_dir, ".lemon", "media-artifacts"])
    proofs_dir = Path.join([tmp_dir, ".lemon", "proofs"])
    File.mkdir_p!(artifacts_dir)
    File.mkdir_p!(proofs_dir)

    artifact_path = Path.join(artifacts_dir, "private-image-output.png")
    File.write!(artifact_path, "generated image bytes")

    {:ok, _job} =
      MediaJobs.record(
        %{
          job_id: "media_test_job",
          type: :image,
          status: :completed,
          provider: "local_svg",
          model: "local",
          channel: "telegram",
          prompt: "private media prompt",
          error: "private media error",
          error_kind: "provider_http_error",
          artifact_path: artifact_path,
          mime_type: "image/png"
        },
        project_dir: tmp_dir
      )

    write_proof!(proofs_dir, "media-image-smoke-latest.json", %{
      status: "failed",
      proof_object: "lemon.media_provider_image",
      reason_kind: "vertex_imagen_http_error:permission_denied",
      details: %{
        provider: "vertex_imagen",
        model: "imagen-test",
        prompt: "private provider prompt",
        provider_response: "private provider response",
        artifact_mime_type: "image/png",
        artifact_bytes: 123
      },
      checks: [%{name: "media_provider_vertex_imagen", status: "failed"}]
    })

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir, artifact_path: artifact_path}
  end

  test "prints redacted media diagnostics", %{tmp_dir: tmp_dir, artifact_path: artifact_path} do
    output =
      capture_io(fn ->
        Media.run(["--project-dir", tmp_dir, "--limit", "1"])
      end)

    assert output =~ "Lemon Media"
    assert output =~ "Jobs: 1"
    assert output =~ "Provider proofs: 0/5 incomplete"
    assert output =~ "image: blocked provider=vertex_imagen"
    assert output =~ "vertex_imagen_http_error:permission_denied"
    assert output =~ "Includes prompts: false"
    assert output =~ "Includes raw artifact paths: false"
    assert output =~ "Includes provider responses: false"
    assert output =~ "Includes secret values: false"
    refute output =~ tmp_dir
    refute output =~ artifact_path
    refute output =~ "private-image-output.png"
    refute output =~ "private media prompt"
    refute output =~ "private media error"
    refute output =~ "private provider prompt"
    refute output =~ "private provider response"
  end

  test "emits redacted JSON", %{tmp_dir: tmp_dir, artifact_path: artifact_path} do
    output =
      capture_io(fn ->
        Media.run(["--project-dir", tmp_dir, "--limit", "1", "--json"])
      end)

    assert {:ok, decoded} = Jason.decode(output)
    assert decoded["summary"]["count"] == 1
    assert decoded["provider_proofs"]["completed_count"] == 0
    assert decoded["cleanup"]["includes_prompts"] == false
    assert decoded["cleanup"]["includes_secret_values"] == false
    refute output =~ tmp_dir
    refute output =~ artifact_path
    refute output =~ "private-image-output.png"
    refute output =~ "private media prompt"
    refute output =~ "private media error"
    refute output =~ "private provider prompt"
    refute output =~ "private provider response"
  end

  defp write_proof!(proofs_dir, filename, proof) do
    File.write!(Path.join(proofs_dir, filename), Jason.encode!(proof))
  end
end
