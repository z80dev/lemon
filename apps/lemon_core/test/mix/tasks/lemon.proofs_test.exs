defmodule Mix.Tasks.Lemon.ProofsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Proofs

  setup do
    Mix.Task.run("loadpaths")

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_proofs_task_test_#{System.unique_integer([:positive])}"
      )

    proofs_dir = Path.join([tmp_dir, ".lemon", "proofs"])
    File.mkdir_p!(proofs_dir)

    proof_path = Path.join(proofs_dir, "demo-proof-latest.json")

    File.write!(proof_path, Jason.encode!(proof_fixture()))

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, proof_path: proof_path}
  end

  test "prints redacted proof inventory without raw paths", %{
    tmp_dir: tmp_dir,
    proof_path: proof_path
  } do
    output =
      capture_io(fn ->
        Proofs.run(["--project-dir", tmp_dir, "--limit", "1"])
      end)

    assert output =~ "Lemon Proofs"
    assert output =~ "Proofs: 1"
    assert output =~ "Completed: 1"
    assert output =~ "Includes raw paths: false"
    assert output =~ "Includes raw filenames: false"
    assert output =~ "proof_hash="
    assert output =~ "demo_check"
    assert output =~ "provider_fallback"
    refute output =~ tmp_dir
    refute output =~ proof_path
    refute output =~ "demo-proof-latest.json"
    refute output =~ "secret prompt"
    refute output =~ "raw provider answer"
  end

  test "emits redacted JSON", %{tmp_dir: tmp_dir, proof_path: proof_path} do
    output =
      capture_io(fn ->
        Proofs.run(["--project-dir", tmp_dir, "--limit", "1", "--json"])
      end)

    assert {:ok, decoded} = Jason.decode(output)
    assert decoded["proof_count"] == 1
    assert decoded["cleanup"]["includes_raw_paths"] == false
    refute output =~ tmp_dir
    refute output =~ proof_path
    refute output =~ "demo-proof-latest.json"
    refute output =~ "secret prompt"
    refute output =~ "raw provider answer"
  end

  defp proof_fixture do
    %{
      "status" => "completed",
      "generated_at" => "2026-05-18T00:00:00Z",
      "completed_count" => 1,
      "failed_count" => 0,
      "skipped_count" => 0,
      "proof_object" => "lemon.demo_proof",
      "prompt" => "secret prompt",
      "provider_response" => "raw provider answer",
      "details" => %{
        "provider" => "openai",
        "model" => "gpt-5",
        "final_provider" => "anthropic"
      },
      "checks" => [
        %{
          "name" => "demo_check",
          "status" => "completed",
          "proof_scope" => "provider_fallback"
        }
      ],
      "cleanup" => %{
        "includes_raw_paths" => false,
        "includes_raw_prompts" => false
      }
    }
  end
end
