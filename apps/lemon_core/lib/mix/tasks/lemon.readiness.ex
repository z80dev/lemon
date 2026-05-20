defmodule Mix.Tasks.Lemon.Readiness do
  @moduledoc """
  Show a compact redacted launch-readiness summary.

  ## Usage

      mix lemon.readiness
      mix lemon.readiness --project-dir /path/to/project --limit 5
      mix lemon.readiness --json
      mix lemon.readiness --strict

  ## Options

    * `--project-dir` - Project root to scan. Defaults to the current directory.
    * `--limit` - Number of unresolved gates to show. Defaults to 10.
    * `--json` - Emit the raw redacted readiness JSON.
    * `--strict` - Fail unless readiness status is `ready`.
  """

  use Mix.Task

  alias LemonCore.Doctor.ReadinessSummary

  @default_limit 10

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project_dir: :string,
          limit: :integer,
          json: :boolean,
          strict: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    project_dir = opts[:project_dir] || File.cwd!()
    limit = normalize_limit(opts[:limit])
    status = ReadinessSummary.status(project_dir: project_dir, limit: limit)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(status, pretty: true))
    else
      print_text(status)
    end

    if opts[:strict] && status.status != "ready" do
      Mix.raise("Readiness is #{status.status}; unresolved gates remain.")
    end
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 1_000)
  defp normalize_limit(_), do: Mix.raise("--limit must be a positive integer")

  defp print_text(status) do
    doctor = status.doctor
    channels = status.channels
    media = status.media_provider
    proofs = status.proofs
    proof_gate_summary = status.proof_gate_summary
    cleanup = status.cleanup

    Mix.shell().info("Lemon Readiness")
    Mix.shell().info("Status: #{status.status}")

    Mix.shell().info(
      "Doctor: #{doctor.overall} pass=#{doctor.pass} warn=#{doctor.warn} fail=#{doctor.fail} skip=#{doctor.skip}"
    )

    Mix.shell().info(
      "Channels: #{channels.status} passed=#{channels.passed_count} blocked=#{channels.blocked_count} warnings=#{channels.warning_count} skipped=#{channels.skipped_count} gates=#{channels.gate_count}"
    )

    Mix.shell().info("Promoted platforms: #{Enum.join(channels.promoted_platforms, ", ")}")
    Mix.shell().info("Provider media: #{media.status} #{media.message}")

    Mix.shell().info(
      "Proofs: #{proofs.proof_count} total, #{proofs.completed_count} completed, #{proofs.failed_count} failed, #{proofs.skipped_count} skipped, #{proofs.invalid_count} invalid"
    )

    Mix.shell().info(
      "Proof gates: #{Map.get(proof_gate_summary, "status", "unknown")} passed=#{Map.get(proof_gate_summary, "passedCount", 0)} blocked=#{Map.get(proof_gate_summary, "blockedCount", 0)} warnings=#{Map.get(proof_gate_summary, "warningCount", 0)} missing=#{Map.get(proof_gate_summary, "missingCount", 0)} gates=#{Map.get(proof_gate_summary, "gateCount", 0)}"
    )

    Mix.shell().info("Includes raw bot tokens: #{cleanup.includes_raw_bot_tokens}")
    Mix.shell().info("Includes secret names: #{cleanup.includes_secret_names}")
    Mix.shell().info("Includes chat IDs: #{cleanup.includes_chat_ids}")
    Mix.shell().info("Includes channel IDs: #{cleanup.includes_channel_ids}")
    Mix.shell().info("Includes message bodies: #{cleanup.includes_message_bodies}")
    Mix.shell().info("Includes raw proof paths: #{cleanup.includes_raw_proof_paths}")
    Mix.shell().info("Includes raw proof details: #{cleanup.includes_raw_proof_details}")
    Mix.shell().info("Includes raw prompts: #{cleanup.includes_raw_prompts}")

    Mix.shell().info(
      "Includes raw provider responses: #{cleanup.includes_raw_provider_responses}"
    )

    Mix.shell().info("Includes secret values: #{cleanup.includes_secret_values}")
    print_unresolved(status.unresolved_gates)
  end

  defp print_unresolved([]), do: Mix.shell().info("Unresolved Gates: none")

  defp print_unresolved(gates) do
    Mix.shell().info("Unresolved Gates:")

    Enum.each(gates, fn gate ->
      reason = if gate.reason_kind, do: " reason=#{gate.reason_kind}", else: ""
      reasons = unresolved_reason_kinds(gate)
      reasons_text = if reasons == [], do: "", else: " reasons=#{Enum.join(reasons, ",")}"
      next_action = if gate.next_action, do: " next=#{gate.next_action}", else: ""

      Mix.shell().info(
        "  #{gate.id}: #{gate.status} evidence=#{gate.evidence}#{reason}#{reasons_text}#{next_action}"
      )
    end)
  end

  defp unresolved_reason_kinds(gate) do
    gate
    |> Map.get(:reason_kinds, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end
end
