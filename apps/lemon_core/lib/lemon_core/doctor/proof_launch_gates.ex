defmodule LemonCore.Doctor.ProofLaunchGates do
  @moduledoc """
  Shared launch-gate summaries derived from redacted proof diagnostics.

  Channel-owned gates (DM, slash registration, client click) are contributed
  by the registered `LemonCore.Doctor.ChannelProofs` spec and merged ahead of
  the core provider-media and terminal-backend gates; without a spec only
  those two core gates remain.
  """

  alias LemonCore.Doctor.ChannelProofs

  @spec status(map()) :: map()
  def status(proof_status) when is_map(proof_status) do
    proofs = Map.get(proof_status, :recent_proofs, [])

    ChannelProofs.call(:launch_gates, [proof_status], %{})
    |> Map.merge(%{
      "providerMedia" => provider_media_gate(proofs),
      "terminalBackends" => terminal_backend_gate(proofs)
    })
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
end
