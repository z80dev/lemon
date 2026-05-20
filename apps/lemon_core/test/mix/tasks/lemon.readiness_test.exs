defmodule Mix.Tasks.Lemon.ReadinessTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Readiness

  setup do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.start")

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_readiness_task_test_#{System.unique_integer([:positive])}"
      )

    proofs_dir = Path.join([tmp_dir, ".lemon", "proofs"])
    File.mkdir_p!(proofs_dir)

    write_proof!(proofs_dir, "media-image-smoke-latest.json", %{
      status: "failed",
      proof_object: "lemon.media_provider_image",
      reason_kind: "vertex_imagen_http_error:permission_denied",
      details: %{
        provider: "vertex_imagen",
        model: "imagen-test",
        prompt: "private readiness prompt",
        provider_response: "private provider response"
      },
      checks: [%{name: "media_provider_vertex_imagen", status: "failed"}]
    })

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "prints redacted readiness summary", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        Readiness.run(["--project-dir", tmp_dir, "--limit", "10"])
      end)

    assert output =~ "Lemon Readiness"
    assert output =~ "Status: blocked"
    assert output =~ "Doctor:"
    assert output =~ "Channels:"
    assert output =~ "Provider media:"
    assert output =~ "Proofs:"
    assert output =~ "Proof gates:"
    assert output =~ "gates=5"
    assert output =~ "Includes raw proof paths: false"
    assert output =~ "Includes raw provider responses: false"
    assert output =~ "Includes secret values: false"
    assert output =~ "Unresolved Gates:"
    assert output =~ "reasons=vertex_imagen_http_error:permission_denied"
    refute output =~ tmp_dir
    refute output =~ "private readiness prompt"
    refute output =~ "private provider response"
  end

  test "emits redacted JSON", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        Readiness.run(["--project-dir", tmp_dir, "--limit", "10", "--json"])
      end)

    assert {:ok, decoded} = Jason.decode(output)
    assert decoded["status"] == "blocked"
    assert decoded["doctor"]["overall"] in ["pass", "warn"]
    assert decoded["proofs"]["proof_count"] == 1
    assert decoded["proof_gates"]["providerMedia"]["status"] == "warning"
    assert decoded["proof_gate_summary"]["gateCount"] == 5
    assert decoded["proof_gate_summary"]["statuses"]["providerMedia"] == "warning"
    provider_media_gate = Enum.find(decoded["unresolved_gates"], &(&1["id"] == "provider_media"))
    assert provider_media_gate["reason_kinds"] == ["vertex_imagen_http_error:permission_denied"]
    assert decoded["cleanup"]["includes_raw_proof_paths"] == false
    assert decoded["cleanup"]["includes_raw_provider_responses"] == false
    refute output =~ tmp_dir
    refute output =~ "private readiness prompt"
    refute output =~ "private provider response"
  end

  test "strict mode fails when readiness is blocked", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/Readiness is blocked/, fn ->
      capture_io(fn ->
        Readiness.run(["--project-dir", tmp_dir, "--limit", "3", "--strict"])
      end)
    end
  end

  defp write_proof!(proofs_dir, filename, proof) do
    File.write!(Path.join(proofs_dir, filename), Jason.encode!(proof))
  end
end
