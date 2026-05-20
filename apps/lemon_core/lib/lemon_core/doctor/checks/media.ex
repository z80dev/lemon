defmodule LemonCore.Doctor.Checks.Media do
  @moduledoc "Checks media provider and channel-delivery readiness from redacted proofs."

  alias LemonCore.Doctor.{Check, ProofDiagnostics}

  @providers [
    {["openai_image", "vertex_imagen"], "image", "scripts/live_media_image_smoke.exs",
     ".lemon/proofs/media-image-smoke-latest.json"},
    {["openai_tts", "elevenlabs_tts", "google_tts"], "TTS", "scripts/live_media_speech_smoke.exs",
     ".lemon/proofs/media-speech-smoke-latest.json"},
    {["openai_transcribe", "deepgram_transcribe"], "STT",
     "scripts/live_media_transcription_smoke.exs",
     ".lemon/proofs/media-transcription-smoke-latest.json"},
    {["openai_vision"], "vision", "scripts/live_media_vision_smoke.exs",
     ".lemon/proofs/media-vision-smoke-latest.json"},
    {["openai_video", "vertex_veo"], "video", "scripts/live_media_video_smoke.exs",
     ".lemon/proofs/media-video-smoke-latest.json"}
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    [
      check_channel_delivery(proofs),
      check_provider_live(proofs)
    ]
  rescue
    error ->
      [
        Check.warn(
          "media.diagnostics",
          "Media proof diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_channel_delivery(proofs) do
    telegram? = completed_delivery?(proofs, :telegram_delivery)
    discord? = completed_delivery?(proofs, :discord_delivery)

    cond do
      telegram? and discord? ->
        Check.pass(
          "media.channel_delivery",
          "Media attachment delivery proof is completed for Telegram and Discord."
        )

      telegram? or discord? ->
        Check.warn(
          "media.channel_delivery",
          "Media attachment delivery proof is only complete for #{delivery_label(telegram?, discord?)}.",
          "Run the generated media/audio or MEDIA directive live matrix for both Telegram and Discord."
        )

      true ->
        Check.warn(
          "media.channel_delivery",
          "Media attachment delivery proof is missing for Telegram and Discord.",
          "Run the Telegram and Discord generated media/audio or MEDIA directive live matrix proofs."
        )
    end
  end

  defp check_provider_live(proofs) do
    statuses = provider_statuses(proofs)
    completed = provider_labels(statuses, "completed")

    cond do
      length(completed) == length(@providers) ->
        Check.pass(
          "media.provider_live",
          "Provider-backed media proofs are completed for #{Enum.join(completed, ", ")}."
        )

      completed == [] ->
        Check.warn(
          "media.provider_live",
          "Provider-backed media proofs are not completed for image, TTS, STT, vision, and video.",
          provider_remediation(statuses)
        )

      true ->
        missing = provider_labels(statuses, "missing")
        skipped = provider_labels(statuses, "skipped")
        failed = provider_labels(statuses, "failed")

        Check.warn(
          "media.provider_live",
          "Provider-backed media proofs are incomplete: completed #{Enum.join(completed, ", ")}#{status_suffix("failed", failed)}#{status_suffix("skipped", skipped)}#{status_suffix("missing", missing)}#{reason_suffix(statuses)}.",
          provider_remediation(statuses)
        )
    end
  end

  defp completed_delivery?(proofs, key) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.any?(fn proof ->
      Map.get(proof, :status) == "completed" and
        get_in(proof, [:media_proof, key]) == true
    end)
  end

  defp delivery_label(true, false), do: "Telegram"
  defp delivery_label(false, true), do: "Discord"
  defp delivery_label(_, _), do: "neither channel"

  defp provider_statuses(proofs) do
    Enum.map(@providers, fn {providers, label, script, proof_path} ->
      %{
        providers: providers,
        label: label,
        script: script,
        proof_path: proof_path,
        status: provider_status(proofs, providers),
        provider: provider_proof_provider(proofs, providers),
        reason_kind: provider_reason_kind(proofs, providers)
      }
    end)
  end

  defp provider_status(proofs, providers) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.filter(&(get_in(&1, [:media_proof, :provider]) in providers))
    |> Enum.map(&Map.get(&1, :status))
    |> best_status()
  end

  defp provider_reason_kind(proofs, providers) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.filter(&(get_in(&1, [:media_proof, :provider]) in providers))
    |> Enum.find_value(fn proof ->
      if Map.get(proof, :status) in ["failed", "skipped"] do
        Map.get(proof, :reason_kind)
      end
    end)
  end

  defp provider_proof_provider(proofs, providers) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.filter(&(get_in(&1, [:media_proof, :provider]) in providers))
    |> Enum.find_value(fn proof ->
      if Map.get(proof, :status) in ["failed", "skipped"] do
        get_in(proof, [:media_proof, :provider])
      end
    end)
  end

  defp best_status(statuses) do
    cond do
      "completed" in statuses -> "completed"
      "failed" in statuses -> "failed"
      "skipped" in statuses -> "skipped"
      true -> "missing"
    end
  end

  defp provider_labels(statuses, status) do
    statuses
    |> Enum.filter(&(&1.status == status))
    |> Enum.map(& &1.label)
  end

  defp status_suffix(_label, []), do: ""
  defp status_suffix(label, values), do: "; #{label} #{Enum.join(values, ", ")}"

  defp reason_suffix(statuses) do
    reasons =
      statuses
      |> Enum.filter(&(&1.status in ["failed", "skipped"] and is_binary(&1.reason_kind)))
      |> Enum.map(&"#{&1.label}=#{&1.reason_kind}")

    case reasons do
      [] -> ""
      _ -> "; reasons #{Enum.join(reasons, ", ")}"
    end
  end

  defp provider_remediation(statuses) do
    commands =
      statuses
      |> Enum.reject(&(&1.status == "completed"))
      |> Enum.map(&provider_command/1)
      |> Enum.join("; ")

    "#{provider_remediation_intro(statuses)} #{commands}. For one-off proof without exporting raw keys, append --api-key-secret SECRET_NAME#{provider_reason_remediation(statuses)}."
  end

  defp provider_remediation_intro(statuses) do
    if Enum.any?(statuses, &(&1.status in ["missing", "skipped"])) do
      "Set provider credentials and run"
    else
      "Inspect provider permissions, quota, or billing and run"
    end
  end

  defp provider_command(status) do
    command =
      "LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start #{status.script} --proof-path #{status.proof_path}"

    if status.status in ["failed", "skipped"] and status.provider in status.providers and
         length(status.providers) > 1 do
      "#{command} --provider #{status.provider}"
    else
      command
    end
  end

  defp provider_reason_remediation(statuses) do
    hints =
      statuses
      |> Enum.filter(&(&1.status in ["failed", "skipped"] and is_binary(&1.reason_kind)))
      |> Enum.map(&provider_reason_hint/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case hints do
      [] -> ""
      _ -> ". Provider hints: #{Enum.join(hints, "; ")}"
    end
  end

  defp provider_reason_hint(%{label: label, reason_kind: reason}) do
    cond do
      String.contains?(reason, "permission_denied") ->
        "#{label} reached the provider but permissions were denied; enable the API and grant IAM/billing access for the configured provider account"

      String.contains?(reason, "billing_limit") ->
        "#{label} reached the provider but hit a billing or quota limit; use a funded project/key or raise the quota"

      String.contains?(reason, "payment_required") ->
        "#{label} reached the provider but payment is required; fund or upgrade the provider account"

      String.contains?(reason, "invalid_request_error") ->
        "#{label} reached the provider but the request was rejected; verify the model, voice, output format, and provider options"

      String.contains?(reason, "provider_http_error") ->
        "#{label} reached the provider but returned an HTTP error; inspect the sanitized proof reason and rerun with the target provider lane"

      true ->
        nil
    end
  end
end
