defmodule LemonCore.Doctor.ProofLaunchGates do
  @moduledoc """
  Shared launch-gate summaries derived from redacted proof diagnostics.
  """

  @spec status(map()) :: map()
  def status(proof_status) when is_map(proof_status) do
    checks = Map.get(proof_status, :latest_checks, [])
    proofs = Map.get(proof_status, :recent_proofs, [])
    reason_counts = Map.get(proof_status, :reason_kind_counts, %{})

    %{
      "discordDm" => discord_dm_gate(checks, reason_counts),
      "discordSlashRegistration" => discord_slash_registration_gate(checks, proofs),
      "discordSlashClientClick" => discord_slash_client_gate(checks, proofs),
      "providerMedia" => provider_media_gate(proofs),
      "terminalBackends" => terminal_backend_gate(proofs)
    }
  end

  def status(_), do: status(%{})

  @spec summary(map()) :: map()
  def summary(launch_gates) when is_map(launch_gates) do
    statuses =
      launch_gates
      |> Enum.map(fn {_gate, value} -> Map.get(value || %{}, "status", "unknown") end)

    %{
      "status" => aggregate_status(statuses),
      "gateCount" => length(statuses),
      "passedCount" => Enum.count(statuses, &(&1 == "passed")),
      "blockedCount" => Enum.count(statuses, &(&1 == "blocked")),
      "warningCount" => Enum.count(statuses, &(&1 == "warning")),
      "missingCount" => Enum.count(statuses, &(&1 == "missing")),
      "statuses" =>
        launch_gates
        |> Enum.map(fn {gate, value} -> {gate, Map.get(value || %{}, "status", "unknown")} end)
        |> Map.new()
    }
  end

  def summary(_), do: summary(%{})

  defp aggregate_status(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 in ["warning", "missing", "unknown"])) -> "warning"
      Enum.empty?(statuses) -> "unknown"
      true -> "passed"
    end
  end

  defp discord_dm_gate(checks, reason_counts) do
    cond do
      latest_check_completed?(checks, "discord_dm_prompt_round_trip") ->
        %{
          "status" => "passed",
          "evidence" => "Discord DM prompt round-trip proof is completed."
        }

      Map.get(reason_counts, "discord_dm_setup_refused", 0) > 0 ->
        %{
          "status" => "blocked",
          "reasonKind" => "discord_dm_setup_refused",
          "evidence" =>
            "Discord DM setup refused because no reachable human/open-DM target was available.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --wait-dm-inbound with --dm-channel-id or --dm-recipient-id for a reachable human/open-DM target."
        }

      true ->
        %{
          "status" => "warning",
          "reasonKind" => "discord_dm_missing",
          "evidence" => "Discord DM prompt round-trip proof has not been captured.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --wait-dm-inbound with --dm-channel-id or --dm-recipient-id."
        }
    end
  end

  defp discord_slash_registration_gate(checks, proofs) do
    cond do
      latest_check_completed?(checks, "discord_all_slash_registration") or
          completed_registration_coverage?(proofs, :contains_all_slash_registration) ->
        %{
          "status" => "passed",
          "evidence" =>
            "Discord application-command registration proof covers all expected Lemon commands."
        }

      latest_check_completed?(checks, "discord_rollback_slash_registration") or
          completed_registration_coverage?(proofs, :contains_rollback_slash_registration) ->
        %{
          "status" => "warning",
          "reasonKind" => "discord_all_slash_registration_missing",
          "evidence" =>
            "Discord /rollback slash registration proof is present but all-command proof is missing.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        }

      latest_check_completed?(checks, "discord_media_slash_registration") or
          completed_registration_coverage?(proofs, :contains_media_slash_registration) ->
        %{
          "status" => "warning",
          "reasonKind" => "discord_all_slash_registration_missing",
          "evidence" =>
            "Discord /media slash registration proof is present but all-command proof is missing.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        }

      true ->
        %{
          "status" => "warning",
          "reasonKind" => "discord_slash_registration_missing",
          "evidence" => "Discord application-command registration proof is missing.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        }
    end
  end

  defp discord_slash_client_gate(checks, proofs) do
    reason =
      latest_check_reason(checks, "discord_slash_client_click_proof_wait") ||
        latest_check_reason(checks, "discord_slash_client_click_proof_artifact") ||
        "discord_slash_client_click_missing"

    cond do
      latest_check_completed?(checks, "discord_slash_client_click_proof_wait") or
        latest_check_completed?(checks, "discord_slash_client_click_proof_artifact") or
          real_client_click_proof?(proofs) ->
        %{
          "status" => "passed",
          "evidence" =>
            "Discord slash client-click proof is completed from a real Discord interaction."
        }

      reason in [
        "discord_slash_client_click_invalid_artifact",
        "discord_slash_client_click_not_promotable",
        "discord_slash_client_click_stale"
      ] ->
        %{
          "status" => "blocked",
          "reasonKind" => reason,
          "evidence" =>
            "Discord slash client-click proof exists but cannot promote the launch gate.",
          "nextAction" =>
            "Rerun scripts/live_discord_matrix.py --wait-slash-client-click-proof while clicking a fresh real Discord slash command."
        }

      true ->
        %{
          "status" => "warning",
          "reasonKind" => reason,
          "evidence" =>
            "Discord slash client-click proof has not been captured from a real Discord client.",
          "nextAction" =>
            "Deploy or hot reload the runtime, then run scripts/live_discord_matrix.py --wait-slash-client-click-proof --channel-id DISCORD_PROOF_CHANNEL_ID while clicking the requested real slash command."
        }
    end
  end

  defp provider_media_gate(proofs) do
    lanes = %{
      "image" => ["openai_image", "vertex_imagen"],
      "tts" => ["openai_tts", "elevenlabs_tts", "google_tts"],
      "stt" => ["openai_transcribe", "deepgram_transcribe"],
      "vision" => ["openai_vision"],
      "video" => ["openai_video", "vertex_veo"]
    }

    lane_statuses =
      lanes
      |> Enum.map(fn {lane, providers} -> {lane, provider_lane_status(proofs, providers)} end)
      |> Map.new()

    completed_lanes =
      Enum.count(lane_statuses, fn {_lane, status} -> status["status"] == "passed" end)

    failed_lanes =
      Enum.count(lane_statuses, fn {_lane, status} -> status["status"] == "blocked" end)

    %{
      "status" => "warning",
      "completedLaneCount" => completed_lanes,
      "totalLaneCount" => map_size(lanes),
      "failedLaneCount" => failed_lanes,
      "lanes" => lane_statuses,
      "nextAction" =>
        "Run the lane-specific scripts/live_media_*_smoke.exs command for failed or missing provider lanes."
    }
    |> maybe_mark_provider_media_passed(completed_lanes, map_size(lanes))
  end

  defp maybe_mark_provider_media_passed(gate, completed_lanes, total_lanes)
       when completed_lanes == total_lanes do
    Map.put(gate, "status", "passed")
  end

  defp maybe_mark_provider_media_passed(gate, _completed_lanes, _total_lanes), do: gate

  defp provider_lane_status(proofs, providers) do
    proof = Enum.find(proofs, &(Map.get(&1, :provider) in providers))

    case proof do
      %{status: "completed", provider: provider} ->
        %{"status" => "passed", "provider" => provider}

      %{status: "failed", provider: provider, reason_kind: reason_kind} ->
        %{
          "status" => "blocked",
          "provider" => provider,
          "reasonKind" => reason_kind || "provider_media_failed"
        }

      %{status: status, provider: provider} when is_binary(status) ->
        %{"status" => "warning", "provider" => provider}

      _ ->
        %{"status" => "missing"}
    end
  end

  defp terminal_backend_gate(proofs) do
    case Enum.find(proofs, &("terminal_backend" in List.wrap(Map.get(&1, :proof_scopes, [])))) do
      %{
        status: "completed",
        completed_count: completed,
        failed_count: failed,
        skipped_count: skipped
      } ->
        %{
          "status" => "passed",
          "completedCount" => completed,
          "failedCount" => failed,
          "skippedCount" => skipped,
          "evidence" => "Terminal backend live proof is completed."
        }

      %{
        status: "failed",
        completed_count: completed,
        failed_count: failed,
        skipped_count: skipped
      } ->
        %{
          "status" => "blocked",
          "completedCount" => completed,
          "failedCount" => failed,
          "skippedCount" => skipped,
          "evidence" => "Terminal backend live proof has failed rows."
        }

      _ ->
        %{
          "status" => "warning",
          "reasonKind" => "terminal_backend_missing",
          "evidence" => "Terminal backend live proof has not been captured."
        }
    end
  end

  defp latest_check_completed?(checks, name) do
    Enum.any?(checks, &(Map.get(&1, :name) == name and Map.get(&1, :status) == "completed"))
  end

  defp completed_registration_coverage?(proofs, key) do
    Enum.any?(proofs, fn proof ->
      Map.get(proof, :status) == "completed" and get_in(proof, [:coverage, key]) == true
    end)
  end

  defp latest_check_reason(checks, name) do
    case Enum.find(checks, &(Map.get(&1, :name) == name)) do
      nil -> nil
      check -> Map.get(check, :reason_kind)
    end
  end

  defp real_client_click_proof?(proofs) do
    Enum.any?(proofs, fn proof ->
      Map.get(proof, :status) == "completed" and
        Map.get(proof, :proof_object) == "lemon.discord_slash_client_click" and
        get_in(proof, [:coverage, :real_client_click_proof]) == true
    end)
  end
end
