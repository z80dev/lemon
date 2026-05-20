defmodule LemonCore.Doctor.Checks.LSP do
  @moduledoc "Checks LSP preview proof readiness from redacted language-server smoke artifacts."

  alias LemonCore.Doctor.{Check, ProofDiagnostics}

  @servers [
    "pyright",
    "gopls",
    "clangd",
    "rust_analyzer",
    "typescript_language_server",
    "elixir_ls"
  ]

  @proofs [
    %{
      label: "project fixtures",
      proof_object: "lsp_project_fixtures_smoke",
      prefix: "lsp_project_fixtures_smoke"
    },
    %{
      label: "real repo fixtures",
      proof_object: "lsp_real_repo_fixtures_smoke",
      prefix: "lsp_real_repo_fixtures_smoke"
    }
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    [check_lsp_preview(proofs)]
  rescue
    error ->
      [
        Check.warn(
          "lsp.preview",
          "LSP proof diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_lsp_preview(proofs) do
    statuses = proof_statuses(proofs)
    completed = labels(statuses, "completed")
    failed = labels(statuses, "failed")
    missing = labels(statuses, "missing")

    cond do
      completed == [] and failed == [] ->
        Check.skip("lsp.preview", "LSP preview proof has not been generated yet.")

      failed != [] or missing != [] ->
        Check.warn(
          "lsp.preview",
          "LSP preview proof is incomplete: completed #{label_list(completed)}#{status_suffix("failed", failed)}#{status_suffix("missing", missing)}.",
          remediation()
        )

      true ->
        Check.pass(
          "lsp.preview",
          "LSP preview proof is completed for project fixtures and real repo fixtures across the full registered server fleet."
        )
    end
  end

  defp proof_statuses(proofs) do
    Enum.map(@proofs, fn proof ->
      %{
        label: proof.label,
        status: proof_status(proofs, proof)
      }
    end)
  end

  defp proof_status(proofs, proof) do
    proof_artifact_status = recent_proof_status(proofs, proof.proof_object)
    check_status = required_check_status(proofs, required_checks(proof.prefix))

    best_status([proof_artifact_status, check_status])
  end

  defp recent_proof_status(proofs, proof_object) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.filter(&(Map.get(&1, :proof_object) == proof_object))
    |> Enum.map(fn proof ->
      cond do
        Map.get(proof, :status) == "completed" and
          Map.get(proof, :completed_count) == length(@servers) and
            Map.get(proof, :failed_count) == 0 ->
          "completed"

        Map.get(proof, :status) == "failed" or Map.get(proof, :failed_count, 0) > 0 ->
          "failed"

        true ->
          "missing"
      end
    end)
    |> best_artifact_status()
  end

  defp required_check_status(proofs, required_checks) do
    check_statuses = Map.get(proofs, :latest_checks, [])

    required_checks
    |> Enum.map(fn name ->
      check_statuses
      |> Enum.filter(&(Map.get(&1, :name) == name))
      |> Enum.map(&Map.get(&1, :status))
      |> best_status()
    end)
    |> best_status()
  end

  defp required_checks(prefix) do
    Enum.map(@servers, &"#{prefix}_#{&1}_editor_flow")
  end

  defp best_status(statuses) do
    cond do
      "failed" in statuses -> "failed"
      "missing" in statuses -> "missing"
      "completed" in statuses -> "completed"
      true -> "missing"
    end
  end

  defp best_artifact_status(statuses) do
    cond do
      "failed" in statuses -> "failed"
      "completed" in statuses -> "completed"
      true -> "missing"
    end
  end

  defp labels(statuses, status) do
    statuses
    |> Enum.filter(&(&1.status == status))
    |> Enum.map(& &1.label)
  end

  defp label_list([]), do: "none"
  defp label_list(labels), do: Enum.join(labels, ", ")

  defp status_suffix(_label, []), do: ""
  defp status_suffix(label, values), do: "; #{label} #{Enum.join(values, ", ")}"

  defp remediation do
    "Run MIX_ENV=test mix run scripts/live_lsp_server_smoke.exs --project-fixtures --editor-flow --out .lemon/proofs/lsp-project-fixtures-latest.json and MIX_ENV=test mix run scripts/live_lsp_server_smoke.exs --real-repo-fixtures --editor-flow --out .lemon/proofs/lsp-real-repo-fixtures-latest.json."
  end
end
