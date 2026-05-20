defmodule LemonCore.Doctor.Checks.ACP do
  @moduledoc "Checks ACP preview proof readiness from redacted stdio proof artifacts."

  alias LemonCore.Doctor.{Check, ProofDiagnostics}

  @proofs [
    %{
      label: "deterministic stdio",
      proof_object: "lemon.acp_stdio_smoke",
      required_count: 6,
      required_checks: [
        {"acp_stdio_initialize", "initialize"},
        {"acp_stdio_session_new", "session/new"},
        {"acp_stdio_queued_prompt", "queued prompt"},
        {"acp_stdio_wait_prompt_updates", "wait updates"},
        {"acp_stdio_session_list_resume_close", "list/resume/close"},
        {"acp_stdio_parse_error", "parse error"}
      ]
    },
    %{
      label: "external Node client",
      proof_object: "lemon.acp_stdio_external_client_smoke",
      required_count: 9,
      required_checks: [
        {"acp_stdio_external_initialize", "external initialize"},
        {"acp_stdio_external_session_new", "external session/new"},
        {"acp_stdio_external_queued_prompt", "external queued prompt"},
        {"acp_stdio_external_wait_prompt_updates", "external wait updates"},
        {"acp_stdio_external_client_file_and_permission_requests",
         "external file/permission requests"},
        {"acp_stdio_external_approval_bus_permission_bridge", "external approval bridge"},
        {"acp_stdio_external_list_resume_close", "external list/resume/close"},
        {"acp_stdio_external_unsupported_image_block", "external unsupported image block"},
        {"acp_stdio_external_parse_error", "external parse error"}
      ]
    },
    %{
      label: "official ACP SDK client",
      proof_object: "lemon.acp_official_sdk_client_smoke",
      required_count: 8,
      required_checks: [
        {"acp_official_sdk_initialize", "SDK initialize"},
        {"acp_official_sdk_session_new", "SDK session/new"},
        {"acp_official_sdk_queued_prompt", "SDK queued prompt"},
        {"acp_official_sdk_wait_prompt_updates", "SDK wait updates"},
        {"acp_official_sdk_client_file_and_permission_requests", "SDK file/permission requests"},
        {"acp_official_sdk_approval_bus_permission_bridge", "SDK approval bridge"},
        {"acp_official_sdk_load_cancel", "SDK load/cancel"},
        {"acp_official_sdk_unsupported_image_block", "SDK unsupported image block"}
      ]
    }
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    [check_acp_preview(proofs)]
  rescue
    error ->
      [
        Check.warn(
          "acp.preview",
          "ACP proof diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_acp_preview(proofs) do
    statuses = proof_statuses(proofs)
    completed = labels(statuses, "completed")
    failed = labels(statuses, "failed")
    missing = labels(statuses, "missing")

    cond do
      completed == [] and failed == [] ->
        Check.skip("acp.preview", "ACP preview proof has not been generated yet.")

      failed != [] or missing != [] ->
        Check.warn(
          "acp.preview",
          "ACP preview proof is incomplete: completed #{label_list(completed)}#{status_suffix("failed", failed)}#{status_suffix("missing", missing)}.",
          remediation()
        )

      true ->
        Check.pass(
          "acp.preview",
          "ACP preview proof is completed for deterministic stdio, external Node client, and official ACP SDK client paths."
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
    proof_artifact_status = recent_proof_status(proofs, proof.proof_object, proof.required_count)
    check_status = required_check_status(proofs, proof.required_checks)

    best_status([proof_artifact_status, check_status])
  end

  defp recent_proof_status(proofs, proof_object, required_count) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.filter(&(Map.get(&1, :proof_object) == proof_object))
    |> Enum.map(fn proof ->
      cond do
        Map.get(proof, :status) == "completed" and
          Map.get(proof, :completed_count) == required_count and
            Map.get(proof, :failed_count) == 0 ->
          "completed"

        Map.get(proof, :status) == "failed" or Map.get(proof, :failed_count, 0) > 0 ->
          "failed"

        true ->
          "missing"
      end
    end)
    |> best_status()
  end

  defp required_check_status(proofs, required_checks) do
    check_statuses = Map.get(proofs, :latest_checks, [])

    required_checks
    |> Enum.map(fn {name, _label} ->
      check_statuses
      |> Enum.filter(&(Map.get(&1, :name) == name))
      |> Enum.map(&Map.get(&1, :status))
      |> best_status()
    end)
    |> best_status()
  end

  defp best_status(statuses) do
    cond do
      "failed" in statuses -> "failed"
      "missing" in statuses -> "missing"
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
    "Run MIX_ENV=test mix run scripts/live_acp_stdio_smoke.exs, node scripts/live_acp_stdio_external_client.mjs, and node scripts/live_acp_official_sdk_client.mjs; keep their redacted proof artifacts under .lemon/proofs/."
  end
end
