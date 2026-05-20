defmodule LemonCore.Doctor.ProofDiagnostics do
  @moduledoc """
  Redacted diagnostics for local live-proof artifacts.
  """

  @default_limit 20

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    limit = Keyword.get(opts, :limit, @default_limit)
    directories = proof_directories(project_dir)
    files = Enum.flat_map(directories, &proof_files/1)
    proofs = Enum.map(files, &proof_status/1)
    valid_proofs = Enum.filter(proofs, & &1.valid)

    %{
      directories: Enum.map(directories, &directory_status/1),
      proof_count: length(valid_proofs),
      invalid_count: Enum.count(proofs, &(not &1.valid)),
      completed_count: Enum.count(valid_proofs, &(&1.status == "completed")),
      failed_count: Enum.count(valid_proofs, &(&1.status == "failed")),
      skipped_count: Enum.count(valid_proofs, &(&1.status == "skipped")),
      status_counts: valid_proofs |> Enum.map(& &1.status) |> Enum.frequencies(),
      proof_scope_counts:
        valid_proofs
        |> Enum.flat_map(& &1.proof_scopes)
        |> Enum.frequencies(),
      check_name_counts:
        valid_proofs
        |> Enum.flat_map(& &1.checks)
        |> Enum.map(& &1.name)
        |> Enum.frequencies(),
      reason_kind_counts:
        valid_proofs
        |> Enum.map(& &1.reason_kind)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies(),
      latest_checks:
        valid_proofs
        |> Enum.flat_map(& &1.checks)
        |> Enum.sort_by(&DateTime.to_unix(&1.modified_at_sort), :desc)
        |> Enum.uniq_by(& &1.name)
        |> Enum.take(limit)
        |> Enum.map(&latest_check/1),
      recent_proofs:
        valid_proofs
        |> Enum.sort_by(&DateTime.to_unix(&1.modified_at_sort), :desc)
        |> Enum.take(limit)
        |> Enum.map(&recent_proof/1),
      cleanup: %{
        includes_raw_paths: false,
        includes_raw_filenames: false,
        includes_raw_proof_details: false,
        includes_raw_prompts: false,
        includes_raw_provider_responses: false,
        embeds_proof_file_contents: false
      }
    }
  end

  defp proof_directories(project_dir) do
    [
      %{label: ".lemon/proofs", path: Path.join([project_dir, ".lemon", "proofs"])},
      %{label: "tmp", path: Path.join(project_dir, "tmp")}
    ]
  end

  defp directory_status(%{label: label, path: path}) do
    files = proof_files(%{path: path})

    %{
      label: label,
      path_hash: hash(path),
      exists: File.dir?(path),
      file_count: length(files)
    }
  end

  defp proof_files(%{label: ".lemon/proofs", path: path}) do
    proof_files(path, ["*proof*.json", "*-latest.json"])
  end

  defp proof_files(%{path: path}) do
    proof_files(path, ["*proof*.json"])
  end

  defp proof_files(path, globs) do
    if File.dir?(path) do
      globs
      |> Enum.flat_map(&Path.wildcard(Path.join(path, &1)))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  defp proof_status(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      stat = File.stat!(path, time: :posix)
      modified_at = DateTime.from_unix!(stat.mtime)
      file_hash = hash(path)
      proof_hash = hash(content)

      %{
        valid: true,
        file_hash: file_hash,
        proof_hash: proof_hash,
        status: proof_status_value(decoded),
        generated_at: nullable_string(value(decoded, "generated_at")),
        modified_at: DateTime.to_iso8601(modified_at),
        modified_at_sort: modified_at,
        completed_count: int_value(value(decoded, "completed_count")),
        failed_count: int_value(value(decoded, "failed_count")),
        skipped_count: int_value(value(decoded, "skipped_count")),
        provider: safe_detail(decoded, "provider"),
        model: safe_detail(decoded, "model"),
        proof_object:
          safe_identifier(value(decoded, "proof_object")) ||
            safe_identifier(value(decoded, "object")) ||
            safe_identifier(value(decoded, "proof")),
        primary_provider: safe_detail(decoded, "primary_provider"),
        fallback_provider: safe_detail(decoded, "fallback_provider"),
        final_provider: safe_detail(decoded, "final_provider"),
        reason_kind: proof_reason_kind(decoded),
        proof_scopes: proof_scopes(decoded),
        coverage: proof_coverage(decoded),
        browser_proof: browser_proof(decoded),
        media_proof: media_proof(decoded),
        terminal_hardening: terminal_hardening(decoded),
        checks: proof_checks(decoded, modified_at, file_hash, proof_hash),
        cleanup: cleanup_flags(value(decoded, "cleanup")),
        redaction: cleanup_flags(value(decoded, "redaction"))
      }
    else
      _ ->
        %{
          valid: false,
          file_hash: hash(path),
          modified_at_sort: DateTime.from_unix!(0)
        }
    end
  end

  defp recent_proof(proof) do
    Map.take(proof, [
      :file_hash,
      :proof_hash,
      :status,
      :generated_at,
      :modified_at,
      :completed_count,
      :failed_count,
      :skipped_count,
      :provider,
      :model,
      :proof_object,
      :primary_provider,
      :fallback_provider,
      :final_provider,
      :proof_scopes,
      :coverage,
      :browser_proof,
      :media_proof,
      :terminal_hardening,
      :reason_kind,
      :cleanup,
      :redaction
    ])
  end

  defp latest_check(check) do
    Map.take(check, [
      :name,
      :status,
      :reason_kind,
      :proof_object,
      :proof_hash,
      :file_hash,
      :generated_at,
      :modified_at
    ])
  end

  defp safe_detail(decoded, key) do
    decoded
    |> value("details")
    |> value(key)
    |> nullable_string()
  end

  defp proof_status_value(decoded) do
    case nullable_string(value(decoded, "status")) do
      nil ->
        status_from_ok(value(decoded, "ok")) ||
          status_from_result(value(decoded, "result")) ||
          status_from_checks(value(decoded, "checks")) ||
          status_from_results(value(decoded, "results")) ||
          "unknown"

      status ->
        status
    end
  end

  defp status_from_ok(true), do: "completed"
  defp status_from_ok(false), do: "failed"
  defp status_from_ok(_), do: nil

  defp status_from_result("passed"), do: "completed"
  defp status_from_result("failed"), do: "failed"
  defp status_from_result(_), do: nil

  defp status_from_checks(checks) when is_list(checks) do
    statuses =
      checks
      |> Enum.filter(&is_map/1)
      |> Enum.map(&check_status_value/1)
      |> Enum.reject(&is_nil/1)

    cond do
      statuses == [] -> nil
      Enum.any?(statuses, &(&1 == "failed")) -> "failed"
      Enum.all?(statuses, &(&1 == "completed")) -> "completed"
      true -> nil
    end
  end

  defp status_from_checks(_), do: nil

  defp check_status_value(check) do
    case nullable_string(value(check, "status")) do
      nil -> status_from_ok(value(check, "ok"))
      status -> status
    end
  end

  defp proof_reason_kind(decoded) do
    safe_detail(decoded, "reason_kind") ||
      nullable_string(value(decoded, "reason_kind")) ||
      failure_hint_kind(decoded) ||
      setup_error_kind(decoded)
  end

  defp proof_scopes(decoded) do
    [
      value(decoded, "proof_scope"),
      value(decoded, "proof"),
      decoded |> value("details") |> value("proof_scope")
    ]
    |> Enum.concat(check_scope_values(value(decoded, "checks")))
    |> Enum.concat(inferred_proof_scopes(decoded))
    |> Enum.map(&safe_scope/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp check_scope_values(checks) when is_list(checks) do
    Enum.map(checks, &value(&1, "proof_scope"))
  end

  defp check_scope_values(_), do: []

  defp inferred_proof_scopes(decoded) do
    details = value(decoded, "details")

    [
      if(
        present?(value(details, "fallback_provider")) or
          present?(value(details, "final_provider")),
        do: "provider_fallback"
      ),
      if(browser_smoke?(decoded), do: "browser_smoke"),
      if(terminal_backend_results?(value(decoded, "results")), do: "terminal_backend"),
      if(openai_compat_results?(decoded), do: "openai_compat_api"),
      acp_scope(decoded),
      mcp_scope(decoded),
      if(media_provider?(value(details, "provider")), do: "media_provider"),
      if(
        generated_media_delivery_checks?(value(decoded, "checks")),
        do: "channel_generated_media_delivery"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp media_provider?(provider) do
    safe_scope(provider) in [
      "openai_image",
      "vertex_imagen",
      "openai_tts",
      "elevenlabs_tts",
      "google_tts",
      "openai_transcribe",
      "deepgram_transcribe",
      "openai_vision",
      "openai_video",
      "vertex_veo"
    ]
  end

  defp generated_media_delivery_checks?(checks) when is_list(checks) do
    Enum.any?(checks, fn check ->
      check
      |> value("name")
      |> safe_scope()
      |> case do
        "telegram_forum_topic_generated_media_delivery" -> true
        "telegram_forum_topic_generated_audio_delivery" -> true
        "telegram_forum_topic_media_directive_delivery" -> true
        "discord_generated_media_delivery" -> true
        "discord_generated_audio_delivery" -> true
        "discord_media_directive_delivery" -> true
        _ -> false
      end
    end)
  end

  defp generated_media_delivery_checks?(_), do: false

  defp terminal_backend_results?(results) when is_list(results) do
    Enum.any?(results, fn result ->
      is_map(result) and
        safe_scope(value(result, "backend")) in [
          "local",
          "local_pty",
          "docker",
          "ssh"
        ]
    end)
  end

  defp terminal_backend_results?(_), do: false

  defp openai_compat_results?(decoded) do
    present?(value(decoded, "endpoint_count")) and is_list(value(decoded, "request_summaries")) and
      decoded
      |> value("results")
      |> openai_compat_result_rows?()
  end

  defp openai_compat_result_rows?(results) when is_list(results) do
    Enum.any?(results, fn result ->
      is_map(result) and present?(value(result, "name")) and present?(value(result, "status"))
    end)
  end

  defp openai_compat_result_rows?(_), do: false

  defp acp_scope(decoded) do
    case safe_identifier(value(decoded, "object")) do
      "lemon.acp_stdio_smoke" -> "acp_stdio"
      "lemon.acp_stdio_external_client_smoke" -> "acp_stdio_external_client"
      "lemon.acp_official_sdk_client_smoke" -> "acp_official_sdk_client"
      _ -> nil
    end
  end

  defp mcp_scope(decoded) do
    case safe_identifier(value(decoded, "proof")) do
      "mcp_stdio_smoke" -> "mcp_stdio"
      "mcp_http_smoke" -> "mcp_http"
      "mcp_sse_smoke" -> "mcp_sse"
      _ -> nil
    end
  end

  defp proof_checks(decoded, modified_at, file_hash, proof_hash) do
    explicit_checks = decoded |> value("checks") |> check_maps()
    result_checks = decoded |> value("results") |> terminal_result_check_maps()
    openai_compat_checks = openai_compat_result_check_maps(decoded)
    acp_checks = acp_result_check_maps(decoded)

    (explicit_checks ++ result_checks ++ openai_compat_checks ++ acp_checks)
    |> Enum.map(&proof_check(&1, decoded, modified_at, file_hash, proof_hash))
    |> Enum.reject(&is_nil/1)
  end

  defp status_from_results(results) when is_list(results) do
    statuses =
      results
      |> Enum.filter(&is_map/1)
      |> Enum.map(&check_status_value/1)
      |> Enum.reject(&is_nil/1)

    cond do
      statuses == [] -> nil
      Enum.any?(statuses, &(&1 == "failed")) -> "failed"
      Enum.all?(statuses, &(&1 == "completed")) -> "completed"
      true -> nil
    end
  end

  defp status_from_results(_), do: nil

  defp check_maps(checks) when is_list(checks), do: Enum.filter(checks, &is_map/1)
  defp check_maps(_), do: []

  defp terminal_result_check_maps(results) when is_list(results) do
    results
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn result ->
      case safe_scope(value(result, "backend")) do
        nil ->
          nil

        backend ->
          %{
            "name" => "terminal_backend_#{backend}",
            "status" => proof_status_value(result),
            "proof_scope" => "terminal_backend"
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp terminal_result_check_maps(_), do: []

  defp openai_compat_result_check_maps(decoded) do
    if openai_compat_results?(decoded) do
      decoded
      |> value("results")
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn result ->
        case safe_scope(value(result, "name")) do
          nil ->
            nil

          name ->
            %{
              "name" => "openai_compat_#{name}",
              "status" => proof_status_value(result),
              "proof_scope" => "openai_compat_api"
            }
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp acp_result_check_maps(decoded) do
    case acp_result_prefix_and_scope(decoded) do
      nil ->
        []

      {prefix, scope} ->
        decoded
        |> value("results")
        |> result_check_maps(prefix, scope)
    end
  end

  defp acp_result_prefix_and_scope(decoded) do
    case safe_identifier(value(decoded, "object")) do
      "lemon.acp_stdio_smoke" ->
        {"acp_stdio", "acp_stdio"}

      "lemon.acp_stdio_external_client_smoke" ->
        {"acp_stdio_external", "acp_stdio_external_client"}

      "lemon.acp_official_sdk_client_smoke" ->
        {"acp_official_sdk", "acp_official_sdk_client"}

      _ ->
        nil
    end
  end

  defp result_check_maps(results, prefix, scope) when is_list(results) do
    results
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn result ->
      case safe_scope(value(result, "name")) do
        nil ->
          nil

        name ->
          %{
            "name" => "#{prefix}_#{name}",
            "status" => proof_status_value(result),
            "proof_scope" => scope
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp result_check_maps(_results, _prefix, _scope), do: []

  defp proof_check(check, decoded, modified_at, file_hash, proof_hash) do
    with name when is_binary(name) <- safe_identifier(value(check, "name")) do
      %{
        name: name,
        status: proof_status_value(check),
        reason_kind: proof_reason_kind(check),
        proof_object:
          safe_identifier(value(check, "proof_object")) ||
            safe_identifier(value(decoded, "proof_object")) ||
            safe_identifier(value(decoded, "object")) ||
            safe_identifier(value(decoded, "proof")),
        generated_at: nullable_string(value(decoded, "generated_at")),
        modified_at: DateTime.to_iso8601(modified_at),
        modified_at_sort: modified_at,
        file_hash: file_hash,
        proof_hash: proof_hash
      }
    end
  end

  defp proof_coverage(decoded) do
    coverage = value(decoded, "coverage")

    if is_map(coverage) do
      %{
        check_count: int_or_nil(value(coverage, "check_count")),
        registered_command_count: int_or_nil(value(coverage, "registered_command_count")),
        decode_command_count: int_or_nil(value(coverage, "decode_command_count")),
        local_response_command_count: int_or_nil(value(coverage, "local_response_command_count")),
        client_click_command_count: int_or_nil(value(coverage, "client_click_command_count")),
        real_client_click_proof: bool_or_nil(value(coverage, "real_client_click_proof")),
        bot_to_bot_sender: bool_or_nil(value(coverage, "bot_to_bot_sender")),
        non_bot_user_sender: bool_or_nil(value(coverage, "non_bot_user_sender")),
        contains_restart_seed: bool_or_nil(value(coverage, "contains_restart_seed")),
        contains_restart_verify: bool_or_nil(value(coverage, "contains_restart_verify")),
        contains_free_response: bool_or_nil(value(coverage, "contains_free_response")),
        contains_dm: bool_or_nil(value(coverage, "contains_dm")),
        contains_thread: bool_or_nil(value(coverage, "contains_thread")),
        contains_generated_media: bool_or_nil(value(coverage, "contains_generated_media")),
        contains_generated_audio: bool_or_nil(value(coverage, "contains_generated_audio")),
        contains_media_directive: bool_or_nil(value(coverage, "contains_media_directive")),
        contains_file_delivery: bool_or_nil(value(coverage, "contains_file_delivery")),
        contains_slash_registration: bool_or_nil(value(coverage, "contains_slash_registration")),
        contains_kanban_slash_registration:
          bool_or_nil(value(coverage, "contains_kanban_slash_registration")),
        contains_checkpoint_slash_registration:
          bool_or_nil(value(coverage, "contains_checkpoint_slash_registration")),
        contains_rollback_slash_registration:
          bool_or_nil(value(coverage, "contains_rollback_slash_registration")),
        contains_media_slash_registration:
          bool_or_nil(value(coverage, "contains_media_slash_registration")),
        contains_all_slash_registration:
          bool_or_nil(value(coverage, "contains_all_slash_registration"))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    else
      %{}
    end
  end

  defp media_proof(decoded) do
    decoded
    |> media_provider_proof()
    |> Map.merge(channel_media_delivery_proof(value(decoded, "checks")))
  end

  defp media_provider_proof(decoded) do
    details = value(decoded, "details")
    provider = safe_detail(decoded, "provider")

    if media_provider?(provider) do
      %{
        provider: provider,
        model: safe_detail(decoded, "model"),
        artifact_mime_type: safe_mime_type(value(details, "artifact_mime_type")),
        artifact_bytes: int_or_nil(value(details, "artifact_bytes")),
        prompt_chars: int_or_nil(value(details, "prompt_chars")),
        input_chars: int_or_nil(value(details, "input_chars")),
        text_chars: int_or_nil(value(details, "text_chars")),
        transcript_chars: int_or_nil(value(details, "transcript_chars")),
        analysis_chars: int_or_nil(value(details, "analysis_chars")),
        has_artifact_hash: present?(value(details, "artifact_hash")),
        has_job_id_hash: present?(value(details, "job_id_hash"))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    else
      %{}
    end
  end

  defp channel_media_delivery_proof(checks) when is_list(checks) do
    checks
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn check, acc ->
      case safe_scope(value(check, "name")) do
        name
        when name in [
               "telegram_forum_topic_generated_media_delivery",
               "telegram_forum_topic_generated_audio_delivery",
               "telegram_forum_topic_media_directive_delivery"
             ] ->
          document = value(check, "document")

          acc
          |> Map.put(:channel_delivery, true)
          |> Map.put(:telegram_delivery, check_status_value(check) == "completed")
          |> maybe_put_atom(
            :telegram_has_document,
            first_non_nil([
              bool_or_nil(value(document, "has_document")),
              bool_or_nil(value(check, "telegram_has_document"))
            ])
          )
          |> maybe_put_atom(:marker_seen, bool_or_nil(value(check, "marker_seen")))
          |> put_media_directive_delivery(name == "telegram_forum_topic_media_directive_delivery")
          |> put_directive_leaked(bool_or_nil(value(check, "directive_leaked")))

        name
        when name in [
               "discord_generated_media_delivery",
               "discord_generated_audio_delivery",
               "discord_media_directive_delivery"
             ] ->
          bot_reply = value(check, "bot_reply")

          acc
          |> Map.put(:channel_delivery, true)
          |> Map.put(:discord_delivery, check_status_value(check) == "completed")
          |> maybe_put_atom(
            :discord_attachment_count,
            int_or_nil(value(bot_reply, "attachment_count")) ||
              int_or_nil(value(check, "attachment_count"))
          )
          |> put_media_directive_delivery(name == "discord_media_directive_delivery")
          |> put_directive_leaked(
            first_non_nil([
              bool_or_nil(value(bot_reply, "directive_leaked")),
              bool_or_nil(value(check, "directive_leaked"))
            ])
          )

        _ ->
          acc
      end
    end)
  end

  defp channel_media_delivery_proof(_), do: %{}

  defp browser_smoke?(decoded) do
    value(decoded, "result") == "passed" and
      (present?(value(decoded, "browser_cdp_attach_completed")) or
         browser_tool_list(decoded) != [])
  end

  defp browser_proof(decoded) do
    if browser_smoke?(decoded) do
      cleanup = value(decoded, "progress_cleanup")

      %{
        completed_count: int_or_nil(value(decoded, "completed_count")),
        failed_count: int_or_nil(value(decoded, "failed_count")),
        exercised_tools: browser_tool_list(decoded),
        progress_update_count: int_or_nil(value(decoded, "progress_update_count")),
        progress_browser_child_action_count:
          int_or_nil(value(decoded, "progress_browser_child_action_count")),
        exercised_tool_count: length(browser_tool_list(decoded)),
        model_visible_image_included: bool_or_nil(value(decoded, "model_visible_image_included")),
        browser_to_media_vision_completed:
          bool_or_nil(value(decoded, "browser_to_media_vision_completed")),
        browser_wait_for_selector_completed:
          bool_or_nil(value(decoded, "browser_wait_for_selector_completed")),
        browser_evaluate_completed: bool_or_nil(value(decoded, "browser_evaluate_completed")),
        browser_hover_completed: bool_or_nil(value(decoded, "browser_hover_completed")),
        browser_select_option_completed:
          bool_or_nil(value(decoded, "browser_select_option_completed")),
        browser_upload_file_completed:
          bool_or_nil(value(decoded, "browser_upload_file_completed")),
        browser_download_completed: bool_or_nil(value(decoded, "browser_download_completed")),
        browser_analyze_completed: bool_or_nil(value(decoded, "browser_analyze_completed")),
        browser_analyze_model_visible_image_included:
          bool_or_nil(value(decoded, "browser_analyze_model_visible_image_included")),
        browser_cdp_attach_completed: bool_or_nil(value(decoded, "browser_cdp_attach_completed")),
        browser_navigation_metadata_blocked:
          bool_or_nil(value(decoded, "browser_navigation_metadata_blocked")),
        browser_navigation_public_route_guarded:
          bool_or_nil(value(decoded, "browser_navigation_public_route_guarded")),
        cleanup: %{
          contains_raw_sensitive_values:
            bool_or_nil(value(cleanup, "contains_raw_sensitive_values")),
          includes_raw_urls: bool_or_nil(value(cleanup, "includes_raw_urls")),
          includes_selectors: bool_or_nil(value(cleanup, "includes_selectors")),
          includes_typed_text: bool_or_nil(value(cleanup, "includes_typed_text")),
          includes_cookie_values: bool_or_nil(value(cleanup, "includes_cookie_values")),
          includes_page_text: bool_or_nil(value(cleanup, "includes_page_text")),
          includes_artifact_paths: bool_or_nil(value(cleanup, "includes_artifact_paths")),
          includes_raw_paths: bool_or_nil(value(cleanup, "includes_raw_paths")),
          includes_screenshot_bytes: bool_or_nil(value(cleanup, "includes_screenshot_bytes"))
        }
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    else
      %{}
    end
  end

  defp browser_tool_list(decoded) do
    case value(decoded, "exercised_tools") do
      tools when is_list(tools) ->
        tools
        |> Enum.map(&safe_scope/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp put_media_directive_delivery(map, true), do: Map.put(map, :media_directive_delivery, true)
  defp put_media_directive_delivery(map, false), do: map

  defp put_directive_leaked(map, nil), do: map
  defp put_directive_leaked(map, true), do: Map.put(map, :directive_leaked, true)
  defp put_directive_leaked(map, false), do: Map.put_new(map, :directive_leaked, false)

  defp first_non_nil(values), do: Enum.find(values, &(not is_nil(&1)))

  defp terminal_hardening(decoded) do
    case docker_hardening_result(value(decoded, "results")) do
      hardening when is_map(hardening) ->
        docker =
          %{
            read_only_rootfs: bool_or_nil(value(hardening, "read_only_rootfs")),
            tmpfs_noexec: bool_or_nil(value(hardening, "tmpfs_noexec")),
            drops_capabilities: bool_or_nil(value(hardening, "drops_capabilities")),
            no_new_privileges: bool_or_nil(value(hardening, "no_new_privileges")),
            cgroup_memory_limit: bool_or_nil(value(hardening, "cgroup_memory_limit")),
            cgroup_cpu_quota: bool_or_nil(value(hardening, "cgroup_cpu_quota")),
            cgroup_pids_limit: bool_or_nil(value(hardening, "cgroup_pids_limit")),
            pull_policy: safe_detail_value(value(hardening, "pull_policy")),
            network: safe_detail_value(value(hardening, "network")),
            memory: safe_detail_value(value(hardening, "memory")),
            cpus: safe_detail_value(value(hardening, "cpus")),
            pids_limit: safe_detail_value(value(hardening, "pids_limit"))
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()

        if map_size(docker) > 0, do: %{docker: docker}, else: %{}

      _ ->
        %{}
    end
  end

  defp docker_hardening_result(results) when is_list(results) do
    Enum.find_value(results, fn result ->
      if is_map(result) and safe_scope(value(result, "backend")) == "docker" do
        hardening = value(result, "hardening")
        if is_map(hardening), do: hardening
      end
    end)
  end

  defp docker_hardening_result(_), do: nil

  defp safe_detail_value(value) do
    case nullable_string(value) do
      nil ->
        nil

      string ->
        if String.match?(string, ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$/) do
          string
        end
    end
  end

  defp safe_mime_type(value) do
    case nullable_string(value) do
      nil ->
        nil

      string ->
        if String.match?(
             string,
             ~r/^[A-Za-z0-9][A-Za-z0-9.+-]{0,63}\/[A-Za-z0-9][A-Za-z0-9.+-]{0,63}$/
           ) do
          string
        end
    end
  end

  defp failure_hint_kind(decoded) do
    hint =
      nullable_string(value(decoded, "failure_hint")) ||
        first_check_failure_hint(value(decoded, "checks"))

    classify_failure_hint(hint)
  end

  defp first_check_failure_hint(checks) when is_list(checks) do
    checks
    |> Enum.find_value(&nullable_string(value(&1, "failure_hint")))
  end

  defp first_check_failure_hint(_), do: nil

  defp setup_error_kind(decoded) do
    error =
      nullable_string(value(decoded, "setup_error")) ||
        first_check_setup_error(value(decoded, "checks"))

    classify_setup_error(error)
  end

  defp first_check_setup_error(checks) when is_list(checks) do
    checks
    |> Enum.find_value(&nullable_string(value(&1, "setup_error")))
  end

  defp first_check_setup_error(_), do: nil

  defp classify_failure_hint(nil), do: nil

  defp classify_failure_hint(hint) do
    normalized = String.downcase(hint)

    cond do
      String.contains?(normalized, "50007") or
          String.contains?(normalized, "cannot send messages to this user") ->
        "discord_dm_setup_refused"

      String.contains?(normalized, "message_content_intent_declared=false") ->
        "discord_message_content_intent_or_delivery"

      String.contains?(normalized, "no lemon reply") and
          String.contains?(normalized, "unmentioned") ->
        "discord_no_reply_for_unmentioned_message"

      String.contains?(normalized, "message content intent") ->
        "discord_message_content_intent_or_delivery"

      true ->
        "proof_failure"
    end
  end

  defp classify_setup_error(nil), do: nil

  defp classify_setup_error(error) do
    normalized = String.downcase(error)

    cond do
      String.contains?(normalized, "50007") or
          String.contains?(normalized, "cannot send messages to this user") ->
        "discord_dm_setup_refused"

      true ->
        "proof_setup_failure"
    end
  end

  defp cleanup_flags(cleanup) when is_map(cleanup) do
    cleanup
    |> Enum.map(fn {key, value} -> {to_string(key), value == true} end)
    |> Map.new()
  end

  defp cleanup_flags(_), do: %{}

  defp value(map, key) when is_map(map) do
    atom = atom_key(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      is_atom(atom) and Map.has_key?(map, atom) -> Map.get(map, atom)
      true -> nil
    end
  end

  defp value(_, _), do: nil

  defp atom_key("cleanup"), do: :cleanup
  defp atom_key("redaction"), do: :redaction
  defp atom_key("completed_count"), do: :completed_count
  defp atom_key("details"), do: :details
  defp atom_key("failed_count"), do: :failed_count
  defp atom_key("generated_at"), do: :generated_at
  defp atom_key("model"), do: :model
  defp atom_key("ok"), do: :ok
  defp atom_key("provider"), do: :provider
  defp atom_key("primary_provider"), do: :primary_provider
  defp atom_key("fallback_provider"), do: :fallback_provider
  defp atom_key("final_provider"), do: :final_provider
  defp atom_key("reason_kind"), do: :reason_kind
  defp atom_key("skipped_count"), do: :skipped_count
  defp atom_key("status"), do: :status
  defp atom_key("failure_hint"), do: :failure_hint
  defp atom_key("checks"), do: :checks
  defp atom_key("setup_error"), do: :setup_error
  defp atom_key("name"), do: :name
  defp atom_key("proof_object"), do: :proof_object
  defp atom_key("proof"), do: :proof
  defp atom_key("proof_scope"), do: :proof_scope
  defp atom_key("result"), do: :result
  defp atom_key("coverage"), do: :coverage
  defp atom_key("results"), do: :results
  defp atom_key("backend"), do: :backend
  defp atom_key("hardening"), do: :hardening
  defp atom_key("artifact_mime_type"), do: :artifact_mime_type
  defp atom_key("artifact_bytes"), do: :artifact_bytes
  defp atom_key("prompt_chars"), do: :prompt_chars
  defp atom_key("input_chars"), do: :input_chars
  defp atom_key("text_chars"), do: :text_chars
  defp atom_key("transcript_chars"), do: :transcript_chars
  defp atom_key("analysis_chars"), do: :analysis_chars
  defp atom_key("artifact_hash"), do: :artifact_hash
  defp atom_key("job_id_hash"), do: :job_id_hash
  defp atom_key("document"), do: :document
  defp atom_key("bot_reply"), do: :bot_reply
  defp atom_key("has_document"), do: :has_document
  defp atom_key("marker_seen"), do: :marker_seen
  defp atom_key("attachment_count"), do: :attachment_count
  defp atom_key("check_count"), do: :check_count
  defp atom_key("registered_command_count"), do: :registered_command_count
  defp atom_key("decode_command_count"), do: :decode_command_count
  defp atom_key("local_response_command_count"), do: :local_response_command_count
  defp atom_key("client_click_command_count"), do: :client_click_command_count
  defp atom_key("real_client_click_proof"), do: :real_client_click_proof
  defp atom_key("bot_to_bot_sender"), do: :bot_to_bot_sender
  defp atom_key("non_bot_user_sender"), do: :non_bot_user_sender
  defp atom_key("contains_restart_seed"), do: :contains_restart_seed
  defp atom_key("contains_restart_verify"), do: :contains_restart_verify
  defp atom_key("contains_free_response"), do: :contains_free_response
  defp atom_key("contains_dm"), do: :contains_dm
  defp atom_key("contains_thread"), do: :contains_thread
  defp atom_key("contains_generated_media"), do: :contains_generated_media
  defp atom_key("contains_generated_audio"), do: :contains_generated_audio
  defp atom_key("contains_media_directive"), do: :contains_media_directive
  defp atom_key("contains_file_delivery"), do: :contains_file_delivery
  defp atom_key("contains_slash_registration"), do: :contains_slash_registration
  defp atom_key("contains_kanban_slash_registration"), do: :contains_kanban_slash_registration

  defp atom_key("contains_checkpoint_slash_registration"),
    do: :contains_checkpoint_slash_registration

  defp atom_key("contains_rollback_slash_registration"),
    do: :contains_rollback_slash_registration

  defp atom_key("contains_media_slash_registration"), do: :contains_media_slash_registration
  defp atom_key("contains_all_slash_registration"), do: :contains_all_slash_registration
  defp atom_key("read_only_rootfs"), do: :read_only_rootfs
  defp atom_key("tmpfs_noexec"), do: :tmpfs_noexec
  defp atom_key("drops_capabilities"), do: :drops_capabilities
  defp atom_key("no_new_privileges"), do: :no_new_privileges
  defp atom_key("cgroup_memory_limit"), do: :cgroup_memory_limit
  defp atom_key("cgroup_cpu_quota"), do: :cgroup_cpu_quota
  defp atom_key("cgroup_pids_limit"), do: :cgroup_pids_limit
  defp atom_key("pull_policy"), do: :pull_policy
  defp atom_key("network"), do: :network
  defp atom_key("memory"), do: :memory
  defp atom_key("cpus"), do: :cpus
  defp atom_key("pids_limit"), do: :pids_limit
  defp atom_key("browser_cdp_attach_completed"), do: :browser_cdp_attach_completed
  defp atom_key("browser_to_media_vision_completed"), do: :browser_to_media_vision_completed
  defp atom_key("browser_wait_for_selector_completed"), do: :browser_wait_for_selector_completed
  defp atom_key("browser_evaluate_completed"), do: :browser_evaluate_completed
  defp atom_key("browser_hover_completed"), do: :browser_hover_completed
  defp atom_key("browser_select_option_completed"), do: :browser_select_option_completed
  defp atom_key("browser_upload_file_completed"), do: :browser_upload_file_completed
  defp atom_key("browser_download_completed"), do: :browser_download_completed
  defp atom_key("browser_analyze_completed"), do: :browser_analyze_completed

  defp atom_key("browser_analyze_model_visible_image_included"),
    do: :browser_analyze_model_visible_image_included

  defp atom_key("browser_navigation_metadata_blocked"), do: :browser_navigation_metadata_blocked

  defp atom_key("browser_navigation_public_route_guarded"),
    do: :browser_navigation_public_route_guarded

  defp atom_key("model_visible_image_included"), do: :model_visible_image_included
  defp atom_key("progress_update_count"), do: :progress_update_count

  defp atom_key("progress_browser_child_action_count"),
    do: :progress_browser_child_action_count

  defp atom_key("progress_cleanup"), do: :progress_cleanup
  defp atom_key("exercised_tools"), do: :exercised_tools
  defp atom_key("contains_raw_sensitive_values"), do: :contains_raw_sensitive_values
  defp atom_key("includes_raw_urls"), do: :includes_raw_urls
  defp atom_key("includes_selectors"), do: :includes_selectors
  defp atom_key("includes_typed_text"), do: :includes_typed_text
  defp atom_key("includes_cookie_values"), do: :includes_cookie_values
  defp atom_key("includes_page_text"), do: :includes_page_text
  defp atom_key("includes_artifact_paths"), do: :includes_artifact_paths
  defp atom_key("includes_raw_paths"), do: :includes_raw_paths
  defp atom_key("includes_screenshot_bytes"), do: :includes_screenshot_bytes
  defp atom_key(_), do: nil

  defp int_value(value) when is_integer(value), do: value
  defp int_value(_), do: 0

  defp int_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp int_or_nil(_), do: nil

  defp bool_or_nil(value) when is_boolean(value), do: value
  defp bool_or_nil(_), do: nil

  defp maybe_put_atom(map, _key, nil), do: map
  defp maybe_put_atom(map, key, value), do: Map.put(map, key, value)

  defp nullable_string(nil), do: nil
  defp nullable_string(value), do: safe_string(value, nil)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp safe_string(value, _default) when is_binary(value), do: value
  defp safe_string(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(_value, default), do: default

  defp safe_identifier(value) do
    case nullable_string(value) do
      nil ->
        nil

      string ->
        if String.match?(string, ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$/) do
          string
        end
    end
  end

  defp safe_scope(value) do
    case nullable_string(value) do
      nil ->
        nil

      string ->
        scope =
          string
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "_")
          |> String.trim("_")
          |> binary_part_safe(0, 80)

        if scope != "", do: scope
    end
  end

  defp binary_part_safe(string, start, length) do
    binary_part(string, start, min(byte_size(string), length))
  end

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
