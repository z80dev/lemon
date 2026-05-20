defmodule LemonCore.Doctor.Checks.Cron do
  @moduledoc "Checks cron preview proof readiness from redacted smoke artifacts."

  alias LemonCore.Doctor.{Check, ProofDiagnostics}

  @proofs [
    %{
      label: "diagnostics",
      proof_object: "lemon.cron_diagnostics_smoke",
      required_count: 4,
      checks: [
        "cron_diagnostics_counts",
        "cron_diagnostics_retry_policy",
        "cron_diagnostics_redaction",
        "cron_support_bundle_entry"
      ],
      cleanup: [
        "includes_raw_session_ids",
        "includes_prompts",
        "includes_outputs",
        "includes_errors",
        "includes_raw_agent_ids",
        "includes_raw_memory_paths",
        "includes_meta_values"
      ]
    },
    %{
      label: "runtime restart",
      proof_object: "lemon.cron_runtime_restart_smoke",
      required_count: 7,
      checks: [
        "runtime_booted",
        "cron_api_ready",
        "pre_restart_scheduled_run_observed",
        "runtime_restarted",
        "persisted_cron_state_loaded",
        "post_restart_scheduled_run_observed",
        "cleanup_complete"
      ],
      cleanup: [
        "includes_raw_prompts",
        "includes_raw_session_ids",
        "includes_raw_outputs",
        "includes_raw_store_path"
      ]
    },
    %{
      label: "channel origin",
      proof_object: "lemon.cron_channel_origin_smoke",
      required_count: 2,
      checks: [
        "telegram_channel_origin_cron_delivery",
        "discord_channel_origin_cron_delivery"
      ],
      cleanup: [
        "includes_raw_session_ids",
        "includes_prompts",
        "includes_outputs",
        "includes_raw_channel_ids",
        "includes_raw_peer_ids",
        "includes_raw_cron_ids"
      ]
    }
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    [check_cron_preview(proofs)]
  rescue
    error ->
      [
        Check.warn(
          "cron.preview",
          "Cron proof diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_cron_preview(proofs) do
    statuses = proof_statuses(proofs)
    completed = labels(statuses, "completed")
    failed = labels(statuses, "failed")
    missing = labels(statuses, "missing")

    cond do
      completed == [] and failed == [] ->
        Check.skip("cron.preview", "Cron preview proof has not been generated yet.")

      failed != [] or missing != [] ->
        Check.warn(
          "cron.preview",
          "Cron preview proof is incomplete: completed #{label_list(completed)}#{status_suffix("failed", failed)}#{status_suffix("missing", missing)}.",
          remediation()
        )

      true ->
        Check.pass(
          "cron.preview",
          "Cron preview proof is completed for diagnostics, runtime restart persistence, and Telegram/Discord-shaped channel-origin delivery."
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
    artifact_status = recent_proof_status(proofs, proof)
    check_status = required_check_status(proofs, proof.checks)

    best_status([artifact_status, check_status])
  end

  defp recent_proof_status(proofs, proof) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.filter(&(Map.get(&1, :proof_object) == proof.proof_object))
    |> Enum.map(fn artifact ->
      cleanup = Map.get(artifact, :cleanup, %{})

      cond do
        Map.get(artifact, :status) == "completed" and
          Map.get(artifact, :completed_count) == proof.required_count and
          Map.get(artifact, :failed_count) == 0 and
          Map.get(artifact, :skipped_count) == 0 and
            Enum.all?(proof.cleanup, &(Map.get(cleanup, &1) == false)) ->
          "completed"

        Map.get(artifact, :status) == "failed" or Map.get(artifact, :failed_count, 0) > 0 ->
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
    "Run MIX_ENV=test mix run scripts/live_cron_diagnostics_smoke.exs, MIX_ENV=dev mix run --no-start scripts/live_cron_runtime_restart_smoke.exs, and MIX_ENV=test mix run scripts/live_cron_channel_origin_smoke.exs; keep their redacted proof artifacts under .lemon/proofs/."
  end
end
