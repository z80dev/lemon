defmodule LemonCore.Doctor.ReadinessSummary do
  @moduledoc """
  Compact redacted launch-readiness summary for operator surfaces.
  """

  alias LemonCore.Doctor
  alias LemonCore.Doctor.{ChannelReadiness, ProofDiagnostics, ProofLaunchGates, Report}

  @default_limit 10

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))
    report = Keyword.get_lazy(opts, :report, fn -> Doctor.report(project_dir: project_dir) end)
    channels = ChannelReadiness.status(project_dir: project_dir)
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)
    proof_gates = ProofLaunchGates.status(proofs)
    media = media_provider_status(report)
    unresolved = unresolved_gates(channels, media, proof_gates, limit)

    %{
      status: overall_status(report, channels, media),
      doctor: %{
        overall: Atom.to_string(Report.overall(report)),
        pass: report.pass,
        warn: report.warn,
        fail: report.fail,
        skip: report.skip
      },
      channels: %{
        status: Map.get(channels, :status, "unknown"),
        promoted_platforms: Map.get(channels, :promoted_platforms, []),
        gate_count: Map.get(channels, :gate_count, 0),
        passed_count: Map.get(channels, :passed_count, 0),
        blocked_count: Map.get(channels, :blocked_count, 0),
        warning_count: Map.get(channels, :warning_count, 0),
        skipped_count: Map.get(channels, :skipped_count, 0)
      },
      media_provider: media,
      proofs: %{
        proof_count: Map.get(proofs, :proof_count, 0),
        completed_count: Map.get(proofs, :completed_count, 0),
        failed_count: Map.get(proofs, :failed_count, 0),
        skipped_count: Map.get(proofs, :skipped_count, 0),
        invalid_count: Map.get(proofs, :invalid_count, 0)
      },
      proof_gates: proof_gates,
      proof_gate_summary: ProofLaunchGates.summary(proof_gates),
      unresolved_gates: unresolved,
      cleanup: cleanup(channels, proofs)
    }
  end

  defp media_provider_status(report) do
    case Enum.find(report.checks, &(&1.name == "media.provider_live")) do
      nil ->
        %{
          status: "unknown",
          message: "Provider-backed media proof status is unavailable.",
          remediation: "Run mix lemon.doctor --verbose."
        }

      check ->
        %{
          status: Atom.to_string(check.status),
          message: check.message,
          remediation: check.remediation
        }
    end
  end

  defp overall_status(report, channels, media) do
    cond do
      report.fail > 0 ->
        "failed"

      Map.get(channels, :blocked_count, 0) > 0 ->
        "blocked"

      Map.get(media, :status) in ["fail", "warn"] ->
        "blocked"

      report.warn > 0 or Map.get(channels, :warning_count, 0) > 0 ->
        "warning"

      true ->
        "ready"
    end
  end

  defp unresolved_gates(channels, media, proof_gates, limit) do
    channel_gates =
      channels
      |> Map.get(:gates, [])
      |> Enum.filter(&(Map.get(&1, :status) in ["blocked", "warning", "skipped"]))
      |> Enum.map(fn gate ->
        %{
          id: Map.get(gate, :id),
          status: Map.get(gate, :status),
          evidence: Map.get(gate, :evidence),
          reason_kind: Map.get(gate, :reason_kind),
          next_action: Map.get(gate, :next_action)
        }
      end)

    media_gate =
      if Map.get(media, :status) in ["fail", "warn", "unknown"] do
        [
          %{
            id: "provider_media",
            status: Map.get(media, :status),
            evidence: "doctor.media.provider_live",
            reason_kind: nil,
            reason_kinds: provider_media_reason_kinds(proof_gates),
            next_action: Map.get(media, :remediation)
          }
        ]
      else
        []
      end

    (channel_gates ++ media_gate)
    |> Enum.take(limit)
  end

  defp provider_media_reason_kinds(proof_gates) do
    proof_gates
    |> Map.get("providerMedia", %{})
    |> Map.get("lanes", %{})
    |> Map.values()
    |> Enum.map(&Map.get(&1, "reasonKind"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cleanup(channels, proofs) do
    channel_cleanup = Map.get(channels, :cleanup, %{})
    proof_cleanup = Map.get(proofs, :cleanup, %{})

    %{
      includes_raw_bot_tokens: truthy(channel_cleanup[:includes_raw_bot_tokens]),
      includes_secret_names: truthy(channel_cleanup[:includes_secret_names]),
      includes_chat_ids: truthy(channel_cleanup[:includes_chat_ids]),
      includes_channel_ids: truthy(channel_cleanup[:includes_channel_ids]),
      includes_message_bodies: truthy(channel_cleanup[:includes_message_bodies]),
      includes_raw_proof_paths:
        truthy(channel_cleanup[:includes_raw_proof_paths]) or
          truthy(proof_cleanup[:includes_raw_paths]),
      includes_raw_proof_details:
        truthy(channel_cleanup[:includes_raw_proof_details]) or
          truthy(proof_cleanup[:includes_raw_proof_details]),
      includes_raw_prompts: truthy(proof_cleanup[:includes_raw_prompts]),
      includes_raw_provider_responses: truthy(proof_cleanup[:includes_raw_provider_responses]),
      includes_secret_values: false
    }
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 1_000)
  defp normalize_limit(_), do: @default_limit

  defp truthy(value), do: value == true
end
