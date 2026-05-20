defmodule LemonControlPlane.Methods.ProofsStatus do
  @moduledoc """
  Handler for `proofs.status`.

  Returns redacted live-proof artifact metadata without raw paths, filenames,
  proof details, prompts, provider responses, or proof file contents.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Doctor.ProofLaunchGates

  @impl true
  def name, do: "proofs.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    project_dir = params["projectDir"] || params["project_dir"] || File.cwd!()
    limit = normalize_limit(params["limit"])

    status =
      LemonCore.Doctor.ProofDiagnostics.status(project_dir: project_dir, limit: max(limit, 1_000))

    payload = %{
      "directories" => Enum.map(Map.get(status, :directories, []), &format_directory/1),
      "proofCount" => Map.get(status, :proof_count, 0),
      "invalidCount" => Map.get(status, :invalid_count, 0),
      "completedCount" => Map.get(status, :completed_count, 0),
      "failedCount" => Map.get(status, :failed_count, 0),
      "skippedCount" => Map.get(status, :skipped_count, 0),
      "statusCounts" => Map.get(status, :status_counts, %{}),
      "reasonKindCounts" => Map.get(status, :reason_kind_counts, %{}),
      "proofScopeCounts" => Map.get(status, :proof_scope_counts, %{}),
      "checkNameCounts" => Map.get(status, :check_name_counts, %{}),
      "launchGates" => ProofLaunchGates.status(status),
      "latestChecks" =>
        status |> Map.get(:latest_checks, []) |> Enum.take(limit) |> Enum.map(&format_check/1),
      "recentProofs" =>
        status |> Map.get(:recent_proofs, []) |> Enum.take(limit) |> Enum.map(&format_proof/1),
      "cleanup" => format_cleanup(Map.get(status, :cleanup, %{}))
    }

    {:ok, Map.put(payload, "summary", summary(payload, limit))}
  rescue
    error ->
      {:error,
       {
         :internal_error,
         "Failed to build proof status",
         Exception.message(error)
       }}
  end

  defp summary(payload, limit) do
    launch_gates = Map.get(payload, "launchGates", %{})

    %{
      "action" => name(),
      "limit" => limit,
      "directoryCount" => length(Map.get(payload, "directories", [])),
      "proofCount" => Map.get(payload, "proofCount", 0),
      "invalidCount" => Map.get(payload, "invalidCount", 0),
      "completedCount" => Map.get(payload, "completedCount", 0),
      "failedCount" => Map.get(payload, "failedCount", 0),
      "skippedCount" => Map.get(payload, "skippedCount", 0),
      "recentProofCount" => length(Map.get(payload, "recentProofs", [])),
      "latestCheckCount" => length(Map.get(payload, "latestChecks", [])),
      "launchGateStatuses" => launch_gate_statuses(launch_gates),
      "cleanup" => Map.get(payload, "cleanup", %{})
    }
  end

  defp launch_gate_statuses(launch_gates) when is_map(launch_gates) do
    launch_gates
    |> Enum.map(fn {gate, value} -> {gate, Map.get(value || %{}, "status")} end)
    |> Map.new()
  end

  defp launch_gate_statuses(_), do: %{}

  defp format_directory(directory) do
    %{
      "label" => Map.get(directory, :label),
      "pathHash" => Map.get(directory, :path_hash),
      "exists" => Map.get(directory, :exists) == true,
      "fileCount" => Map.get(directory, :file_count, 0)
    }
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 1_000)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> min(parsed, 1_000)
      _ -> 20
    end
  end

  defp normalize_limit(_), do: 20

  defp format_proof(proof) do
    %{
      "fileHash" => Map.get(proof, :file_hash),
      "proofHash" => Map.get(proof, :proof_hash),
      "status" => Map.get(proof, :status),
      "generatedAt" => Map.get(proof, :generated_at),
      "modifiedAt" => Map.get(proof, :modified_at),
      "completedCount" => Map.get(proof, :completed_count, 0),
      "failedCount" => Map.get(proof, :failed_count, 0),
      "skippedCount" => Map.get(proof, :skipped_count, 0),
      "provider" => Map.get(proof, :provider),
      "model" => Map.get(proof, :model),
      "proofObject" => Map.get(proof, :proof_object),
      "primaryProvider" => Map.get(proof, :primary_provider),
      "fallbackProvider" => Map.get(proof, :fallback_provider),
      "finalProvider" => Map.get(proof, :final_provider),
      "proofScopes" => Map.get(proof, :proof_scopes, []),
      "coverage" => format_coverage(Map.get(proof, :coverage, %{})),
      "mediaProof" => format_media_proof(Map.get(proof, :media_proof, %{})),
      "terminalHardening" => format_terminal_hardening(Map.get(proof, :terminal_hardening, %{})),
      "reasonKind" => Map.get(proof, :reason_kind),
      "cleanup" => Map.get(proof, :cleanup, %{}),
      "redaction" => format_redaction(Map.get(proof, :redaction, %{}))
    }
  end

  defp format_coverage(coverage) when is_map(coverage) do
    %{}
    |> maybe_put("checkCount", Map.get(coverage, :check_count))
    |> maybe_put("registeredCommandCount", Map.get(coverage, :registered_command_count))
    |> maybe_put("decodeCommandCount", Map.get(coverage, :decode_command_count))
    |> maybe_put("localResponseCommandCount", Map.get(coverage, :local_response_command_count))
    |> maybe_put("clientClickCommandCount", Map.get(coverage, :client_click_command_count))
    |> maybe_put("realClientClickProof", Map.get(coverage, :real_client_click_proof))
    |> maybe_put("botToBotSender", Map.get(coverage, :bot_to_bot_sender))
    |> maybe_put("nonBotUserSender", Map.get(coverage, :non_bot_user_sender))
    |> maybe_put("containsRestartSeed", Map.get(coverage, :contains_restart_seed))
    |> maybe_put("containsRestartVerify", Map.get(coverage, :contains_restart_verify))
    |> maybe_put("containsFreeResponse", Map.get(coverage, :contains_free_response))
    |> maybe_put("containsDm", Map.get(coverage, :contains_dm))
    |> maybe_put("containsThread", Map.get(coverage, :contains_thread))
    |> maybe_put("containsGeneratedMedia", Map.get(coverage, :contains_generated_media))
    |> maybe_put("containsGeneratedAudio", Map.get(coverage, :contains_generated_audio))
    |> maybe_put("containsMediaDirective", Map.get(coverage, :contains_media_directive))
    |> maybe_put("containsFileDelivery", Map.get(coverage, :contains_file_delivery))
    |> maybe_put("containsSlashRegistration", Map.get(coverage, :contains_slash_registration))
    |> maybe_put(
      "containsKanbanSlashRegistration",
      Map.get(coverage, :contains_kanban_slash_registration)
    )
    |> maybe_put(
      "containsCheckpointSlashRegistration",
      Map.get(coverage, :contains_checkpoint_slash_registration)
    )
    |> maybe_put(
      "containsRollbackSlashRegistration",
      Map.get(coverage, :contains_rollback_slash_registration)
    )
    |> maybe_put(
      "containsMediaSlashRegistration",
      Map.get(coverage, :contains_media_slash_registration)
    )
    |> maybe_put(
      "containsAllSlashRegistration",
      Map.get(coverage, :contains_all_slash_registration)
    )
  end

  defp format_coverage(_), do: %{}

  defp format_media_proof(media_proof) when is_map(media_proof) do
    %{}
    |> maybe_put("provider", Map.get(media_proof, :provider))
    |> maybe_put("model", Map.get(media_proof, :model))
    |> maybe_put("artifactMimeType", Map.get(media_proof, :artifact_mime_type))
    |> maybe_put("artifactBytes", Map.get(media_proof, :artifact_bytes))
    |> maybe_put("promptChars", Map.get(media_proof, :prompt_chars))
    |> maybe_put("inputChars", Map.get(media_proof, :input_chars))
    |> maybe_put("textChars", Map.get(media_proof, :text_chars))
    |> maybe_put("transcriptChars", Map.get(media_proof, :transcript_chars))
    |> maybe_put("analysisChars", Map.get(media_proof, :analysis_chars))
    |> maybe_put("hasArtifactHash", Map.get(media_proof, :has_artifact_hash))
    |> maybe_put("hasJobIdHash", Map.get(media_proof, :has_job_id_hash))
    |> maybe_put("channelDelivery", Map.get(media_proof, :channel_delivery))
    |> maybe_put("telegramDelivery", Map.get(media_proof, :telegram_delivery))
    |> maybe_put("telegramHasDocument", Map.get(media_proof, :telegram_has_document))
    |> maybe_put("discordDelivery", Map.get(media_proof, :discord_delivery))
    |> maybe_put("discordAttachmentCount", Map.get(media_proof, :discord_attachment_count))
    |> maybe_put("mediaDirectiveDelivery", Map.get(media_proof, :media_directive_delivery))
    |> maybe_put("directiveLeaked", Map.get(media_proof, :directive_leaked))
    |> maybe_put("markerSeen", Map.get(media_proof, :marker_seen))
  end

  defp format_media_proof(_), do: %{}

  defp format_terminal_hardening(%{docker: docker}) when is_map(docker) do
    %{
      "docker" =>
        %{}
        |> maybe_put("readOnlyRootfs", Map.get(docker, :read_only_rootfs))
        |> maybe_put("tmpfsNoexec", Map.get(docker, :tmpfs_noexec))
        |> maybe_put("dropsCapabilities", Map.get(docker, :drops_capabilities))
        |> maybe_put("noNewPrivileges", Map.get(docker, :no_new_privileges))
        |> maybe_put("cgroupMemoryLimit", Map.get(docker, :cgroup_memory_limit))
        |> maybe_put("cgroupCpuQuota", Map.get(docker, :cgroup_cpu_quota))
        |> maybe_put("cgroupPidsLimit", Map.get(docker, :cgroup_pids_limit))
        |> maybe_put("pullPolicy", Map.get(docker, :pull_policy))
        |> maybe_put("network", Map.get(docker, :network))
        |> maybe_put("memory", Map.get(docker, :memory))
        |> maybe_put("cpus", Map.get(docker, :cpus))
        |> maybe_put("pidsLimit", Map.get(docker, :pids_limit))
    }
  end

  defp format_terminal_hardening(_), do: %{}

  defp format_check(check) do
    %{
      "name" => Map.get(check, :name),
      "status" => Map.get(check, :status),
      "reasonKind" => Map.get(check, :reason_kind),
      "proofObject" => Map.get(check, :proof_object),
      "generatedAt" => Map.get(check, :generated_at),
      "modifiedAt" => Map.get(check, :modified_at),
      "fileHash" => Map.get(check, :file_hash),
      "proofHash" => Map.get(check, :proof_hash)
    }
  end

  defp format_cleanup(cleanup) when is_map(cleanup) do
    %{
      "includesRawPaths" => Map.get(cleanup, :includes_raw_paths, false),
      "includesRawFilenames" => Map.get(cleanup, :includes_raw_filenames, false),
      "includesRawProofDetails" => Map.get(cleanup, :includes_raw_proof_details, false),
      "includesRawPrompts" => Map.get(cleanup, :includes_raw_prompts, false),
      "includesRawProviderResponses" => Map.get(cleanup, :includes_raw_provider_responses, false),
      "embedsProofFileContents" => Map.get(cleanup, :embeds_proof_file_contents, false)
    }
  end

  defp format_cleanup(_), do: format_cleanup(%{})

  defp format_redaction(redaction) when is_map(redaction) do
    redaction
    |> Enum.map(fn {key, value} -> {camelize_key(key), value == true} end)
    |> Map.new()
  end

  defp format_redaction(_), do: %{}

  defp camelize_key(key) do
    key
    |> to_string()
    |> String.split("_", trim: true)
    |> case do
      [] ->
        ""

      [first | rest] ->
        first <> Enum.map_join(rest, "", &String.capitalize/1)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
