defmodule LemonCore.Doctor.ExtensionDiagnostics do
  @moduledoc """
  Redacted extension/plugin directory diagnostics for support bundles.
  """

  alias LemonCore.Config
  alias LemonCore.Extensions.Manifest

  @extension_globs ["*.ex", "*.exs", "*/lib/**/*.ex"]

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    config = Config.load(project_dir, cache: false)
    paths = extension_paths(config, project_dir)
    directories = Enum.map(paths, &directory_status/1)
    manifests = Enum.flat_map(directories, & &1.manifests)
    host_type_counts = count_manifest_values(manifests, & &1.host_types)
    execution = execution_policy(config)

    %{
      directories: directories,
      directory_count: length(directories),
      existing_directory_count: Enum.count(directories, & &1.exists),
      extension_file_count: Enum.reduce(directories, 0, &(&1.extension_file_count + &2)),
      manifest_count: length(manifests),
      valid_manifest_count: Enum.count(manifests, & &1.valid),
      invalid_manifest_count: Enum.count(manifests, &(not &1.valid)),
      configured_extension_path_count: configured_extension_path_count(config),
      capability_counts: count_manifest_values(manifests, & &1.capabilities),
      provider_type_counts: count_manifest_values(manifests, & &1.provider_types),
      host_type_counts: host_type_counts,
      distribution_source_counts: count_manifest_values(manifests, & &1.distribution_sources),
      audit_status_counts: count_manifest_values(manifests, & &1.audit_statuses),
      execution: execution,
      host_runtime: host_runtime(config, host_type_counts, execution),
      execution_telemetry: execution_telemetry(project_dir),
      wasm_telemetry: wasm_telemetry(project_dir),
      wasm_policy: wasm_policy(project_dir),
      registry_audit: registry_audit(project_dir),
      wasm_lifecycle: wasm_lifecycle(project_dir),
      cleanup: %{
        includes_raw_source_paths: false,
        includes_file_contents: false,
        includes_load_error_messages: false,
        includes_manifest_contents: false,
        includes_distribution_urls: false,
        loads_extension_code: false
      }
    }
  end

  defp host_runtime(config, host_type_counts, execution) do
    invalid_hosts =
      ["beam", "wasm", "mcp", "external"]
      |> Map.new(fn host ->
        {host,
         %{
           configured_count: Map.get(host_type_counts, host, 0),
           status: host_status(host, config, host_type_counts, execution),
           diagnostics_loads_host_code: false
         }}
      end)

    %{
      hosts: invalid_hosts,
      degraded_host_count:
        Enum.count(invalid_hosts, fn {_host, meta} -> meta.status == "degraded" end),
      manifest_only_host_count:
        Enum.count(invalid_hosts, fn {_host, meta} -> meta.status == "manifest_only" end),
      runtime_health_loads_extension_code: false
    }
  end

  defp execution_telemetry(project_dir) do
    proof_path = Path.join([project_dir, ".lemon", "proofs", "extension-host-smoke-latest.json"])

    with {:ok, body} <- File.read(proof_path),
         {:ok, proof} <- Jason.decode(body) do
      telemetry_check = find_check(proof, "extension_tool_execution_emits_redacted_telemetry")
      disabled_check = find_check(proof, "extensions_disabled_blocks_explicit_path_execution")

      env_disabled_check =
        find_check(proof, "extensions_env_disabled_blocks_explicit_path_execution")

      redaction = map_value(proof, "redaction") || %{}
      disabled_check_completed? = map_value(disabled_check, "status") == "completed"
      env_disabled_check_completed? = map_value(env_disabled_check, "status") == "completed"

      %{
        proof_present: true,
        proof_hash: hash(body),
        proof_status: safe_string(map_value(proof, "status")),
        generated_at: safe_string(map_value(proof, "generated_at")),
        completed_count: integer_value(map_value(proof, "completed_count")),
        failed_count: integer_value(map_value(proof, "failed_count")),
        telemetry_check_status: safe_string(map_value(telemetry_check, "status")),
        disabled_check_status: safe_string(map_value(disabled_check, "status")),
        env_disabled_check_status: safe_string(map_value(env_disabled_check, "status")),
        emits_redacted_start_stop_exception:
          map_value(telemetry_check, "status") == "completed" and
            redaction_clean?(redaction),
        blocks_disabled_explicit_paths:
          disabled_check_completed? and env_disabled_check_completed?,
        redaction: %{
          contains_raw_paths: truthy?(map_value(redaction, "contains_raw_paths")),
          contains_file_contents: truthy?(map_value(redaction, "contains_file_contents")),
          contains_load_error_messages:
            truthy?(map_value(redaction, "contains_load_error_messages")),
          contains_tool_result_payload:
            truthy?(map_value(redaction, "contains_tool_result_payload"))
        }
      }
    else
      _ -> empty_execution_telemetry()
    end
  end

  defp wasm_telemetry(project_dir) do
    proof_path = Path.join([project_dir, ".lemon", "proofs", "wasm-tool-telemetry-latest.json"])

    with {:ok, body} <- File.read(proof_path),
         {:ok, proof} <- Jason.decode(body) do
      success_check = find_check(proof, "wasm_tool_success_emits_redacted_start_stop_telemetry")
      error_check = find_check(proof, "wasm_tool_error_emits_redacted_error_status")
      exception_check = find_check(proof, "wasm_tool_exit_emits_redacted_exception_telemetry")
      redaction_check = find_check(proof, "wasm_tool_telemetry_omits_raw_sensitive_values")
      redaction = map_value(proof, "redaction") || %{}
      host_boundary = map_value(proof, "host_boundary") || %{}

      %{
        proof_present: true,
        proof_hash: hash(body),
        proof_status: safe_string(map_value(proof, "status")),
        generated_at: safe_string(map_value(proof, "generated_at")),
        completed_count: integer_value(map_value(proof, "completed_count")),
        failed_count: integer_value(map_value(proof, "failed_count")),
        success_check_status: safe_string(map_value(success_check, "status")),
        error_check_status: safe_string(map_value(error_check, "status")),
        exception_check_status: safe_string(map_value(exception_check, "status")),
        redaction_check_status: safe_string(map_value(redaction_check, "status")),
        emits_redacted_start_stop_exception:
          checks_completed?([success_check, error_check, exception_check, redaction_check]) and
            wasm_redaction_clean?(redaction),
        host_boundary: %{
          host: safe_string(map_value(host_boundary, "host")),
          emits_start_stop_exception:
            truthy?(map_value(host_boundary, "emits_start_stop_exception")),
          uses_hashed_wasm_paths: truthy?(map_value(host_boundary, "uses_hashed_wasm_paths")),
          tool_count: integer_value(map_value(host_boundary, "tool_count"))
        },
        redaction: %{
          contains_raw_paths: truthy?(map_value(redaction, "contains_raw_paths")),
          contains_raw_params: truthy?(map_value(redaction, "contains_raw_params")),
          contains_raw_tool_call_ids: truthy?(map_value(redaction, "contains_raw_tool_call_ids")),
          contains_sidecar_error_text:
            truthy?(map_value(redaction, "contains_sidecar_error_text")),
          contains_tool_result_payload:
            truthy?(map_value(redaction, "contains_tool_result_payload"))
        }
      }
    else
      _ -> empty_wasm_telemetry()
    end
  end

  defp empty_wasm_telemetry do
    %{
      proof_present: false,
      proof_hash: nil,
      proof_status: "missing",
      generated_at: nil,
      completed_count: 0,
      failed_count: 0,
      success_check_status: "missing",
      error_check_status: "missing",
      exception_check_status: "missing",
      redaction_check_status: "missing",
      emits_redacted_start_stop_exception: false,
      host_boundary: %{
        host: nil,
        emits_start_stop_exception: false,
        uses_hashed_wasm_paths: false,
        tool_count: 0
      },
      redaction: %{
        contains_raw_paths: false,
        contains_raw_params: false,
        contains_raw_tool_call_ids: false,
        contains_sidecar_error_text: false,
        contains_tool_result_payload: false
      }
    }
  end

  defp wasm_policy(project_dir) do
    proof_path = Path.join([project_dir, ".lemon", "proofs", "wasm-policy-latest.json"])

    with {:ok, body} <- File.read(proof_path),
         {:ok, proof} <- Jason.decode(body) do
      http_check = find_check(proof, "wasm_policy_http_requires_approval")
      tool_invoke_check = find_check(proof, "wasm_policy_tool_invoke_requires_approval")
      exec_check = find_check(proof, "wasm_policy_exec_requires_approval")
      safe_check = find_check(proof, "wasm_policy_safe_capabilities_execute_without_approval")
      override_check = find_check(proof, "wasm_policy_explicit_never_overrides_default_approval")
      boundary = map_value(proof, "policy_boundary") || %{}
      redaction = map_value(proof, "redaction") || %{}

      %{
        proof_present: true,
        proof_hash: hash(body),
        proof_status: safe_string(map_value(proof, "status")),
        generated_at: safe_string(map_value(proof, "generated_at")),
        completed_count: integer_value(map_value(proof, "completed_count")),
        failed_count: integer_value(map_value(proof, "failed_count")),
        http_check_status: safe_string(map_value(http_check, "status")),
        tool_invoke_check_status: safe_string(map_value(tool_invoke_check, "status")),
        exec_check_status: safe_string(map_value(exec_check, "status")),
        safe_check_status: safe_string(map_value(safe_check, "status")),
        override_check_status: safe_string(map_value(override_check, "status")),
        capability_approval_defaults:
          checks_completed?([http_check, tool_invoke_check, exec_check, safe_check]) and
            wasm_policy_redaction_clean?(redaction),
        explicit_override_supported: map_value(override_check, "status") == "completed",
        policy_boundary: %{
          http_requires_approval_by_default:
            truthy?(map_value(boundary, "http_requires_approval_by_default")),
          tool_invoke_requires_approval_by_default:
            truthy?(map_value(boundary, "tool_invoke_requires_approval_by_default")),
          exec_requires_approval_by_default:
            truthy?(map_value(boundary, "exec_requires_approval_by_default")),
          safe_capabilities_execute_without_approval:
            truthy?(map_value(boundary, "safe_capabilities_execute_without_approval")),
          explicit_never_can_override_default:
            truthy?(map_value(boundary, "explicit_never_can_override_default"))
        },
        redaction: %{
          contains_raw_paths: truthy?(map_value(redaction, "contains_raw_paths")),
          contains_raw_params: truthy?(map_value(redaction, "contains_raw_params")),
          contains_raw_tool_call_ids: truthy?(map_value(redaction, "contains_raw_tool_call_ids"))
        }
      }
    else
      _ -> empty_wasm_policy()
    end
  end

  defp empty_wasm_policy do
    %{
      proof_present: false,
      proof_hash: nil,
      proof_status: "missing",
      generated_at: nil,
      completed_count: 0,
      failed_count: 0,
      http_check_status: "missing",
      tool_invoke_check_status: "missing",
      exec_check_status: "missing",
      safe_check_status: "missing",
      override_check_status: "missing",
      capability_approval_defaults: false,
      explicit_override_supported: false,
      policy_boundary: %{
        http_requires_approval_by_default: false,
        tool_invoke_requires_approval_by_default: false,
        exec_requires_approval_by_default: false,
        safe_capabilities_execute_without_approval: false,
        explicit_never_can_override_default: false
      },
      redaction: %{
        contains_raw_paths: false,
        contains_raw_params: false,
        contains_raw_tool_call_ids: false
      }
    }
  end

  defp registry_audit(project_dir) do
    proof_path =
      Path.join([project_dir, ".lemon", "proofs", "extension-registry-audit-latest.json"])

    with {:ok, body} <- File.read(proof_path),
         {:ok, proof} <- Jason.decode(body) do
      validate_check = find_check(proof, "extension_registry_validates_code_free_index")
      block_check = find_check(proof, "extension_registry_blocks_unaudited_install")
      update_check = find_check(proof, "extension_registry_detects_audited_update")
      no_code_check = find_check(proof, "extension_registry_audit_does_not_load_code")
      redaction_check = find_check(proof, "extension_registry_audit_redacts_sensitive_values")
      boundary = map_value(proof, "registry_boundary") || %{}
      redaction = map_value(proof, "redaction") || %{}

      %{
        proof_present: true,
        proof_hash: hash(body),
        proof_status: safe_string(map_value(proof, "status")),
        generated_at: safe_string(map_value(proof, "generated_at")),
        completed_count: integer_value(map_value(proof, "completed_count")),
        failed_count: integer_value(map_value(proof, "failed_count")),
        validate_check_status: safe_string(map_value(validate_check, "status")),
        block_check_status: safe_string(map_value(block_check, "status")),
        update_check_status: safe_string(map_value(update_check, "status")),
        no_code_check_status: safe_string(map_value(no_code_check, "status")),
        redaction_check_status: safe_string(map_value(redaction_check, "status")),
        registry_workflow_supported:
          checks_completed?([
            validate_check,
            block_check,
            update_check,
            no_code_check,
            redaction_check
          ]) and
            registry_audit_redaction_clean?(redaction),
        registry_boundary: %{
          validates_manifest_metadata:
            truthy?(map_value(boundary, "validates_manifest_metadata")),
          blocks_unaudited_installs: truthy?(map_value(boundary, "blocks_unaudited_installs")),
          detects_update_candidates: truthy?(map_value(boundary, "detects_update_candidates")),
          loads_extension_code: truthy?(map_value(boundary, "loads_extension_code")),
          installable_count: integer_value(map_value(boundary, "installable_count")),
          blocked_count: integer_value(map_value(boundary, "blocked_count")),
          update_candidate_count: integer_value(map_value(boundary, "update_candidate_count")),
          blocked_update_count: integer_value(map_value(boundary, "blocked_update_count"))
        },
        redaction: %{
          contains_raw_registry_paths:
            truthy?(map_value(redaction, "contains_raw_registry_paths")),
          contains_distribution_urls: truthy?(map_value(redaction, "contains_distribution_urls")),
          contains_package_names: truthy?(map_value(redaction, "contains_package_names")),
          contains_manifest_contents: truthy?(map_value(redaction, "contains_manifest_contents"))
        }
      }
    else
      _ -> empty_registry_audit()
    end
  end

  defp empty_registry_audit do
    %{
      proof_present: false,
      proof_hash: nil,
      proof_status: "missing",
      generated_at: nil,
      completed_count: 0,
      failed_count: 0,
      validate_check_status: "missing",
      block_check_status: "missing",
      update_check_status: "missing",
      no_code_check_status: "missing",
      redaction_check_status: "missing",
      registry_workflow_supported: false,
      registry_boundary: %{
        validates_manifest_metadata: false,
        blocks_unaudited_installs: false,
        detects_update_candidates: false,
        loads_extension_code: false,
        installable_count: 0,
        blocked_count: 0,
        update_candidate_count: 0,
        blocked_update_count: 0
      },
      redaction: %{
        contains_raw_registry_paths: false,
        contains_distribution_urls: false,
        contains_package_names: false,
        contains_manifest_contents: false
      }
    }
  end

  defp wasm_lifecycle(project_dir) do
    proof_path = Path.join([project_dir, ".lemon", "proofs", "wasm-lifecycle-latest.json"])

    with {:ok, body} <- File.read(proof_path),
         {:ok, proof} <- Jason.decode(body) do
      discover_check = find_check(proof, "wasm_lifecycle_discover_emits_redacted_start_stop")
      invoke_check = find_check(proof, "wasm_lifecycle_invoke_emits_redacted_start_stop")
      status_check = find_check(proof, "wasm_lifecycle_status_tracks_running_sidecar")
      stop_check = find_check(proof, "wasm_lifecycle_stop_terminates_sidecar")
      redaction_check = find_check(proof, "wasm_lifecycle_telemetry_omits_raw_sensitive_values")
      boundary = map_value(proof, "lifecycle_boundary") || %{}
      redaction = map_value(proof, "redaction") || %{}

      %{
        proof_present: true,
        proof_hash: hash(body),
        proof_status: safe_string(map_value(proof, "status")),
        generated_at: safe_string(map_value(proof, "generated_at")),
        completed_count: integer_value(map_value(proof, "completed_count")),
        failed_count: integer_value(map_value(proof, "failed_count")),
        discover_check_status: safe_string(map_value(discover_check, "status")),
        invoke_check_status: safe_string(map_value(invoke_check, "status")),
        status_check_status: safe_string(map_value(status_check, "status")),
        stop_check_status: safe_string(map_value(stop_check, "status")),
        redaction_check_status: safe_string(map_value(redaction_check, "status")),
        lifecycle_supported:
          checks_completed?([
            discover_check,
            invoke_check,
            status_check,
            stop_check,
            redaction_check
          ]) and
            wasm_lifecycle_redaction_clean?(redaction),
        lifecycle_boundary: %{
          host: safe_string(map_value(boundary, "host")),
          discover_emits_redacted_start_stop:
            truthy?(map_value(boundary, "discover_emits_redacted_start_stop")),
          invoke_emits_redacted_start_stop:
            truthy?(map_value(boundary, "invoke_emits_redacted_start_stop")),
          status_tracks_running_sidecar:
            truthy?(map_value(boundary, "status_tracks_running_sidecar")),
          stop_terminates_sidecar: truthy?(map_value(boundary, "stop_terminates_sidecar")),
          tool_count: integer_value(map_value(boundary, "tool_count"))
        },
        redaction: %{
          contains_raw_cwd: truthy?(map_value(redaction, "contains_raw_cwd")),
          contains_raw_session_ids: truthy?(map_value(redaction, "contains_raw_session_ids")),
          contains_raw_tool_names: truthy?(map_value(redaction, "contains_raw_tool_names")),
          contains_raw_params: truthy?(map_value(redaction, "contains_raw_params"))
        }
      }
    else
      _ -> empty_wasm_lifecycle()
    end
  end

  defp empty_wasm_lifecycle do
    %{
      proof_present: false,
      proof_hash: nil,
      proof_status: "missing",
      generated_at: nil,
      completed_count: 0,
      failed_count: 0,
      discover_check_status: "missing",
      invoke_check_status: "missing",
      status_check_status: "missing",
      stop_check_status: "missing",
      redaction_check_status: "missing",
      lifecycle_supported: false,
      lifecycle_boundary: %{
        host: nil,
        discover_emits_redacted_start_stop: false,
        invoke_emits_redacted_start_stop: false,
        status_tracks_running_sidecar: false,
        stop_terminates_sidecar: false,
        tool_count: 0
      },
      redaction: %{
        contains_raw_cwd: false,
        contains_raw_session_ids: false,
        contains_raw_tool_names: false,
        contains_raw_params: false
      }
    }
  end

  defp checks_completed?(checks) do
    Enum.all?(checks, &(map_value(&1, "status") == "completed"))
  end

  defp wasm_redaction_clean?(redaction) do
    not truthy?(map_value(redaction, "contains_raw_paths")) and
      not truthy?(map_value(redaction, "contains_raw_params")) and
      not truthy?(map_value(redaction, "contains_raw_tool_call_ids")) and
      not truthy?(map_value(redaction, "contains_sidecar_error_text")) and
      not truthy?(map_value(redaction, "contains_tool_result_payload"))
  end

  defp wasm_policy_redaction_clean?(redaction) do
    not truthy?(map_value(redaction, "contains_raw_paths")) and
      not truthy?(map_value(redaction, "contains_raw_params")) and
      not truthy?(map_value(redaction, "contains_raw_tool_call_ids"))
  end

  defp registry_audit_redaction_clean?(redaction) do
    not truthy?(map_value(redaction, "contains_raw_registry_paths")) and
      not truthy?(map_value(redaction, "contains_distribution_urls")) and
      not truthy?(map_value(redaction, "contains_package_names")) and
      not truthy?(map_value(redaction, "contains_manifest_contents"))
  end

  defp wasm_lifecycle_redaction_clean?(redaction) do
    not truthy?(map_value(redaction, "contains_raw_cwd")) and
      not truthy?(map_value(redaction, "contains_raw_session_ids")) and
      not truthy?(map_value(redaction, "contains_raw_tool_names")) and
      not truthy?(map_value(redaction, "contains_raw_params"))
  end

  defp empty_execution_telemetry do
    %{
      proof_present: false,
      proof_hash: nil,
      proof_status: "missing",
      generated_at: nil,
      completed_count: 0,
      failed_count: 0,
      telemetry_check_status: "missing",
      disabled_check_status: "missing",
      env_disabled_check_status: "missing",
      emits_redacted_start_stop_exception: false,
      blocks_disabled_explicit_paths: false,
      redaction: %{
        contains_raw_paths: false,
        contains_file_contents: false,
        contains_load_error_messages: false,
        contains_tool_result_payload: false
      }
    }
  end

  defp find_check(proof, name) do
    proof
    |> map_value("checks")
    |> List.wrap()
    |> Enum.find(%{}, &(map_value(&1, "name") == name))
  end

  defp redaction_clean?(redaction) do
    not truthy?(map_value(redaction, "contains_raw_paths")) and
      not truthy?(map_value(redaction, "contains_file_contents")) and
      not truthy?(map_value(redaction, "contains_load_error_messages")) and
      not truthy?(map_value(redaction, "contains_tool_result_payload"))
  end

  defp host_status("beam", _config, host_type_counts, execution) do
    cond do
      execution.enabled == false -> "disabled"
      Map.get(host_type_counts, "beam", 0) == 0 -> "not_configured"
      execution.configured_extension_path_count > 0 -> "loadable"
      execution.default_directories_diagnostics_only -> "diagnostics_only"
      true -> "loadable"
    end
  end

  defp host_status("wasm", config, host_type_counts, _execution) do
    cond do
      Map.get(host_type_counts, "wasm", 0) == 0 -> "not_configured"
      wasm_enabled?(config) -> "configured"
      true -> "disabled"
    end
  end

  defp host_status(host, _config, host_type_counts, _execution)
       when host in ["mcp", "external"] do
    if Map.get(host_type_counts, host, 0) > 0, do: "manifest_only", else: "not_configured"
  end

  defp extension_paths(config, project_dir) do
    [
      Path.join([home_dir(), ".lemon", "agent", "extensions"]),
      Path.join([project_dir, ".lemon", "extensions"])
      | configured_extension_paths(config, project_dir)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp configured_extension_paths(%Config{agent: agent}, project_dir) when is_map(agent) do
    agent
    |> map_value(:extension_paths)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&expand_path(&1, project_dir))
  end

  defp configured_extension_paths(_, _), do: []

  defp configured_extension_path_count(%Config{agent: agent}) when is_map(agent) do
    agent
    |> map_value(:extension_paths)
    |> List.wrap()
    |> Enum.count(&is_binary/1)
  end

  defp configured_extension_path_count(_), do: 0

  defp execution_policy(config) do
    auto_load? = auto_load_default_paths?(config)

    %{
      enabled: extensions_enabled?(config),
      configured_extension_path_count: configured_extension_path_count(config),
      default_directory_count: 2,
      auto_load_default_paths: auto_load?,
      default_directories_diagnostics_only: not auto_load?,
      diagnostics_loads_extension_code: false
    }
  end

  defp auto_load_default_paths?(%Config{agent: agent}) when is_map(agent) do
    agent
    |> map_value(:extensions)
    |> map_value(:auto_load_default_paths)
    |> truthy?()
  end

  defp auto_load_default_paths?(_), do: false

  defp extensions_enabled?(%Config{agent: agent}) when is_map(agent) do
    agent
    |> map_value(:extensions)
    |> map_value(:enabled)
    |> enabled?()
  end

  defp extensions_enabled?(_), do: true

  defp directory_status(path) do
    files = extension_files(path)
    manifests = manifest_files(path) |> Enum.map(&manifest_status/1)

    %{
      path_hash: hash(path),
      exists: File.dir?(path),
      extension_file_count: length(files),
      extension_file_hashes: Enum.map(files, &hash/1),
      nested_lib_file_count: Enum.count(files, &String.contains?(&1, "/lib/")),
      manifest_file_count: length(manifests),
      valid_manifest_count: Enum.count(manifests, & &1.valid),
      invalid_manifest_count: Enum.count(manifests, &(not &1.valid)),
      manifest_file_hashes: Enum.map(manifests, & &1.file_hash),
      manifests: manifests
    }
  end

  defp extension_files(path) do
    if File.dir?(path) do
      @extension_globs
      |> Enum.flat_map(&Path.wildcard(Path.join(path, &1)))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  defp manifest_files(path) do
    Manifest.discover(path)
  end

  defp manifest_status(path) do
    validation = Manifest.validate_file(path)

    %{
      file_hash: validation.path_hash,
      valid: validation.valid?,
      byte_size: validation.byte_size,
      error_count: length(validation.errors),
      error_hashes: Enum.map(validation.errors, &hash/1),
      capabilities: validation.capabilities,
      provider_types: validation.provider_types,
      host_types: validation.host_types,
      distribution_sources: validation.distribution_sources,
      audit_statuses: validation.audit_statuses
    }
  end

  defp count_manifest_values(manifests, fun) do
    manifests
    |> Enum.flat_map(fun)
    |> Enum.frequencies()
    |> Map.new(fn {key, count} -> {key, count} end)
  end

  defp expand_path(path, project_dir) do
    cond do
      String.starts_with?(path, "~/") -> Path.expand(path)
      Path.type(path) == :absolute -> Path.expand(path)
      true -> Path.expand(path, project_dir)
    end
  end

  defp home_dir do
    System.user_home() || "~"
  end

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp map_value(_, _), do: nil

  defp truthy?(value), do: value in [true, "true", 1]

  defp enabled?(value) when value in [false, "false", 0], do: false
  defp enabled?(_), do: true

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_), do: 0

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(_), do: nil

  defp wasm_enabled?(%Config{agent: agent}) when is_map(agent) do
    agent
    |> map_value(:tools)
    |> map_value(:wasm)
    |> map_value(:enabled)
    |> truthy?()
  end

  defp wasm_enabled?(_), do: false

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
