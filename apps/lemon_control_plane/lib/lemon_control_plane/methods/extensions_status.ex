defmodule LemonControlPlane.Methods.ExtensionsStatus do
  @moduledoc """
  Handler for `extensions.status`.

  Returns redacted extension/plugin health for operator views. Raw extension
  source paths, load-error messages, and config schemas are not returned.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Doctor.ExtensionDiagnostics

  @impl true
  def name, do: "extensions.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    cwd = project_dir(params || %{})
    paths = extension_paths(cwd, params || %{})
    enabled? = extensions_enabled?(cwd)
    load_paths = if enabled?, do: paths, else: []

    {:ok, extensions, load_errors, validation_errors} =
      CodingAgent.Extensions.load_extensions_with_errors(load_paths)

    provider_specs = CodingAgent.Extensions.get_providers(extensions)

    tool_conflicts =
      CodingAgent.ToolRegistry.tool_conflict_report(cwd, extension_paths: load_paths)

    extension_info = CodingAgent.Extensions.get_info(extensions)
    manifest_status = safe_manifest_status(cwd)

    payload = %{
      "extensions" => Enum.map(extension_info, &format_extension/1),
      "paths" => Enum.map(paths, &format_path/1),
      "execution" => execution_policy(cwd, paths, params || %{}, enabled?),
      "executionTelemetry" => format_execution_telemetry(manifest_status[:execution_telemetry]),
      "wasmTelemetry" => format_wasm_telemetry(manifest_status[:wasm_telemetry]),
      "wasmPolicy" => format_wasm_policy(manifest_status[:wasm_policy]),
      "registryAudit" => format_registry_audit(manifest_status[:registry_audit]),
      "wasmLifecycle" => format_wasm_lifecycle(manifest_status[:wasm_lifecycle]),
      "loadErrors" => Enum.map(load_errors, &format_load_error/1),
      "validationErrors" => Enum.map(validation_errors, &format_validation_error/1),
      "toolConflicts" => format_tool_conflicts(tool_conflicts),
      "providerRegistration" => format_provider_specs(provider_specs),
      "hostRuntime" =>
        host_runtime(
          cwd,
          length(extensions),
          length(load_errors),
          length(validation_errors),
          tool_conflicts,
          manifest_status
        ),
      "wasm" => format_wasm(tool_conflicts[:wasm]),
      "totalLoaded" => length(extensions),
      "totalErrors" => length(load_errors),
      "totalValidationErrors" => length(validation_errors),
      "status" =>
        status(enabled?, length(load_errors), length(validation_errors), tool_conflicts),
      "cleanup" => %{
        "includesRawSourcePaths" => false,
        "includesLoadErrorMessages" => false,
        "includesConfigSchemas" => false,
        "includesProviderModules" => false
      }
    }

    {:ok, Map.put(payload, "summary", summary(payload))}
  rescue
    error ->
      {:error,
       {
         :internal_error,
         "Failed to build extensions status",
         Exception.message(error)
       }}
  end

  defp summary(payload) do
    provider_registration = Map.get(payload, "providerRegistration", %{})
    tool_conflicts = Map.get(payload, "toolConflicts", %{})
    execution = Map.get(payload, "execution", %{})
    host_runtime = Map.get(payload, "hostRuntime", %{})

    %{
      "action" => name(),
      "status" => Map.get(payload, "status"),
      "extensionCount" => length(Map.get(payload, "extensions", [])),
      "pathCount" => length(Map.get(payload, "paths", [])),
      "totalLoaded" => Map.get(payload, "totalLoaded", 0),
      "totalErrors" => Map.get(payload, "totalErrors", 0),
      "totalValidationErrors" => Map.get(payload, "totalValidationErrors", 0),
      "providerCount" => Map.get(provider_registration, "configuredProviderCount", 0),
      "providerConflictCount" => Map.get(provider_registration, "conflictCount", 0),
      "toolConflictCount" => length(Map.get(tool_conflicts, "conflicts", [])),
      "enabled" => Map.get(execution, "enabled") == true,
      "candidatePathCount" => Map.get(execution, "candidatePathCount", 0),
      "loadedPathCount" => Map.get(execution, "loadedPathCount", 0),
      "hostStatuses" => host_statuses(host_runtime),
      "cleanup" => Map.get(payload, "cleanup", %{})
    }
  end

  defp host_statuses(host_runtime) when is_map(host_runtime) do
    host_runtime
    |> Enum.filter(fn {_host, value} -> is_map(value) end)
    |> Enum.map(fn {host, value} -> {host, Map.get(value, "status")} end)
    |> Map.new()
  end

  defp host_statuses(_), do: %{}

  defp project_dir(params) do
    case params["projectDir"] || params["project_dir"] || params["cwd"] do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> File.cwd!()
    end
  end

  defp extension_paths(cwd, params) do
    case params["extensionPaths"] || params["extension_paths"] do
      paths when is_list(paths) ->
        paths
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&Path.expand/1)

      _ ->
        trusted_configured_paths(cwd) ++ default_paths_if_trusted(cwd)
    end
  end

  defp execution_policy(cwd, paths, params, enabled?) do
    explicit? = is_list(params["extensionPaths"] || params["extension_paths"])
    auto_load? = default_paths_auto_load?(cwd)

    %{
      "enabled" => enabled?,
      "explicitPathsProvided" => explicit?,
      "autoLoadDefaultPaths" => auto_load?,
      "candidatePathCount" => length(paths),
      "loadedPathCount" => if(enabled?, do: length(paths), else: 0),
      "defaultDirectoryCount" => length(default_extension_paths(cwd)),
      "defaultDirectoriesDiagnosticsOnly" => not explicit? and not auto_load?,
      "trustBoundary" =>
        "extensions.enabled=false disables extension code execution; extension_paths and explicit extensionPaths can execute code only when extensions are enabled; default directories execute only when auto_load_default_paths is true"
    }
  end

  defp trusted_configured_paths(cwd) do
    cwd
    |> load_agent_config()
    |> Map.get(:extension_paths, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&expand_path(&1, cwd))
  end

  defp default_paths_if_trusted(cwd) do
    if default_paths_auto_load?(cwd), do: default_extension_paths(cwd), else: []
  end

  defp default_paths_auto_load?(cwd) do
    cwd
    |> load_agent_config()
    |> Map.get(:extensions, %{})
    |> map_value(:auto_load_default_paths)
    |> truthy?()
  end

  defp extensions_enabled?(cwd) do
    cwd
    |> load_agent_config()
    |> Map.get(:extensions, %{})
    |> map_value(:enabled)
    |> enabled?()
  end

  defp load_agent_config(cwd) do
    cwd
    |> LemonCore.Config.load(cache: false)
    |> Map.get(:agent, %{})
  rescue
    _ -> %{}
  end

  defp default_extension_paths(cwd) do
    [
      CodingAgent.Config.extensions_dir(),
      CodingAgent.Config.project_extensions_dir(cwd)
    ]
  end

  defp expand_path(path, cwd) do
    cond do
      String.starts_with?(path, "~/") -> Path.expand(path)
      Path.type(path) == :absolute -> Path.expand(path)
      true -> Path.expand(path, cwd)
    end
  end

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp map_value(_, _), do: nil

  defp format_extension(info) do
    %{
      "name" => to_string(info[:name] || "unknown"),
      "version" => to_string(info[:version] || "0.0.0"),
      "module" => module_name(info[:module]),
      "sourcePathHash" => hash_optional(info[:source_path]),
      "capabilities" => Enum.map(info[:capabilities] || [], &to_string/1),
      "hasConfigSchema" => map_size(info[:config_schema] || %{}) > 0
    }
  end

  defp format_path(path) do
    %{
      "pathHash" => hash_optional(path),
      "exists" => File.dir?(Path.expand(path))
    }
  end

  defp format_load_error(error) do
    %{
      "sourcePathHash" => hash_optional(error[:source_path]),
      "errorType" => error[:error] |> error_type(),
      "errorMessageHash" => hash_optional(error[:error_message])
    }
  end

  defp format_validation_error(error) do
    errors = error[:errors] || []

    %{
      "module" => module_name(error[:module]),
      "sourcePathHash" => hash_optional(error[:source_path]),
      "errorCount" => length(errors),
      "errorHashes" => Enum.map(errors, &hash_optional/1)
    }
  end

  defp format_tool_conflicts(report) when is_map(report) do
    %{
      "conflicts" => Enum.map(report[:conflicts] || [], &format_tool_conflict/1),
      "totalTools" => report[:total_tools] || 0,
      "builtinCount" => report[:builtin_count] || 0,
      "wasmCount" => report[:wasm_count] || 0,
      "extensionCount" => report[:extension_count] || 0,
      "shadowedCount" => report[:shadowed_count] || 0,
      "loadErrorCount" => length(report[:load_errors] || [])
    }
  end

  defp format_tool_conflicts(_), do: %{}

  defp format_tool_conflict(conflict) do
    %{
      "toolName" => conflict[:tool_name],
      "winner" => format_source(conflict[:winner]),
      "shadowed" => Enum.map(conflict[:shadowed] || [], &format_source/1)
    }
  end

  defp format_provider_specs(provider_specs) do
    providers =
      provider_specs
      |> Enum.map(fn {spec, extension} ->
        %{
          "type" => safe_string(spec[:type]),
          "name" => safe_string(spec[:name]),
          "extension" => module_name(extension)
        }
      end)
      |> Enum.sort_by(&{&1["type"], &1["name"], &1["extension"]})

    %{
      "configuredProviderCount" => length(providers),
      "providers" => providers,
      "conflictCount" => provider_conflict_count(providers)
    }
  end

  defp provider_conflict_count(providers) do
    providers
    |> Enum.group_by(&{&1["type"], &1["name"]})
    |> Enum.count(fn {_key, group} -> length(group) > 1 end)
  end

  defp format_wasm(nil), do: nil

  defp format_wasm(wasm) when is_map(wasm) do
    %{
      "enabled" => truthy?(wasm[:enabled] || wasm["enabled"]),
      "running" => truthy?(wasm[:running] || wasm["running"]),
      "toolCount" => wasm[:tool_count] || wasm["tool_count"] || 0,
      "reason" => wasm[:reason] || wasm["reason"]
    }
  end

  defp format_wasm(_), do: nil

  defp format_execution_telemetry(telemetry) when is_map(telemetry) do
    redaction = telemetry[:redaction] || %{}

    %{
      "proofPresent" => Map.get(telemetry, :proof_present, false),
      "proofHash" => Map.get(telemetry, :proof_hash),
      "proofStatus" => Map.get(telemetry, :proof_status, "missing"),
      "generatedAt" => Map.get(telemetry, :generated_at),
      "completedCount" => Map.get(telemetry, :completed_count, 0),
      "failedCount" => Map.get(telemetry, :failed_count, 0),
      "telemetryCheckStatus" => Map.get(telemetry, :telemetry_check_status, "missing"),
      "disabledCheckStatus" => Map.get(telemetry, :disabled_check_status, "missing"),
      "envDisabledCheckStatus" => Map.get(telemetry, :env_disabled_check_status, "missing"),
      "emitsRedactedStartStopException" =>
        Map.get(telemetry, :emits_redacted_start_stop_exception, false),
      "blocksDisabledExplicitPaths" => Map.get(telemetry, :blocks_disabled_explicit_paths, false),
      "redaction" => %{
        "containsRawPaths" => Map.get(redaction, :contains_raw_paths, false),
        "containsFileContents" => Map.get(redaction, :contains_file_contents, false),
        "containsLoadErrorMessages" => Map.get(redaction, :contains_load_error_messages, false),
        "containsToolResultPayload" => Map.get(redaction, :contains_tool_result_payload, false)
      }
    }
  end

  defp format_execution_telemetry(_), do: format_execution_telemetry(%{})

  defp format_wasm_telemetry(telemetry) when is_map(telemetry) do
    redaction = telemetry[:redaction] || %{}
    host_boundary = telemetry[:host_boundary] || %{}

    %{
      "proofPresent" => Map.get(telemetry, :proof_present, false),
      "proofHash" => Map.get(telemetry, :proof_hash),
      "proofStatus" => Map.get(telemetry, :proof_status, "missing"),
      "generatedAt" => Map.get(telemetry, :generated_at),
      "completedCount" => Map.get(telemetry, :completed_count, 0),
      "failedCount" => Map.get(telemetry, :failed_count, 0),
      "successCheckStatus" => Map.get(telemetry, :success_check_status, "missing"),
      "errorCheckStatus" => Map.get(telemetry, :error_check_status, "missing"),
      "exceptionCheckStatus" => Map.get(telemetry, :exception_check_status, "missing"),
      "redactionCheckStatus" => Map.get(telemetry, :redaction_check_status, "missing"),
      "emitsRedactedStartStopException" =>
        Map.get(telemetry, :emits_redacted_start_stop_exception, false),
      "hostBoundary" => %{
        "host" => Map.get(host_boundary, :host),
        "emitsStartStopException" => Map.get(host_boundary, :emits_start_stop_exception, false),
        "usesHashedWasmPaths" => Map.get(host_boundary, :uses_hashed_wasm_paths, false),
        "toolCount" => Map.get(host_boundary, :tool_count, 0)
      },
      "redaction" => %{
        "containsRawPaths" => Map.get(redaction, :contains_raw_paths, false),
        "containsRawParams" => Map.get(redaction, :contains_raw_params, false),
        "containsRawToolCallIds" => Map.get(redaction, :contains_raw_tool_call_ids, false),
        "containsSidecarErrorText" => Map.get(redaction, :contains_sidecar_error_text, false),
        "containsToolResultPayload" => Map.get(redaction, :contains_tool_result_payload, false)
      }
    }
  end

  defp format_wasm_telemetry(_), do: format_wasm_telemetry(%{})

  defp format_wasm_policy(policy) when is_map(policy) do
    boundary = policy[:policy_boundary] || %{}
    redaction = policy[:redaction] || %{}

    %{
      "proofPresent" => Map.get(policy, :proof_present, false),
      "proofHash" => Map.get(policy, :proof_hash),
      "proofStatus" => Map.get(policy, :proof_status, "missing"),
      "generatedAt" => Map.get(policy, :generated_at),
      "completedCount" => Map.get(policy, :completed_count, 0),
      "failedCount" => Map.get(policy, :failed_count, 0),
      "httpCheckStatus" => Map.get(policy, :http_check_status, "missing"),
      "toolInvokeCheckStatus" => Map.get(policy, :tool_invoke_check_status, "missing"),
      "execCheckStatus" => Map.get(policy, :exec_check_status, "missing"),
      "safeCheckStatus" => Map.get(policy, :safe_check_status, "missing"),
      "overrideCheckStatus" => Map.get(policy, :override_check_status, "missing"),
      "capabilityApprovalDefaults" => Map.get(policy, :capability_approval_defaults, false),
      "explicitOverrideSupported" => Map.get(policy, :explicit_override_supported, false),
      "policyBoundary" => %{
        "httpRequiresApprovalByDefault" =>
          Map.get(boundary, :http_requires_approval_by_default, false),
        "toolInvokeRequiresApprovalByDefault" =>
          Map.get(boundary, :tool_invoke_requires_approval_by_default, false),
        "execRequiresApprovalByDefault" =>
          Map.get(boundary, :exec_requires_approval_by_default, false),
        "safeCapabilitiesExecuteWithoutApproval" =>
          Map.get(boundary, :safe_capabilities_execute_without_approval, false),
        "explicitNeverCanOverrideDefault" =>
          Map.get(boundary, :explicit_never_can_override_default, false)
      },
      "redaction" => %{
        "containsRawPaths" => Map.get(redaction, :contains_raw_paths, false),
        "containsRawParams" => Map.get(redaction, :contains_raw_params, false),
        "containsRawToolCallIds" => Map.get(redaction, :contains_raw_tool_call_ids, false)
      }
    }
  end

  defp format_wasm_policy(_), do: format_wasm_policy(%{})

  defp format_registry_audit(audit) when is_map(audit) do
    boundary = audit[:registry_boundary] || %{}
    redaction = audit[:redaction] || %{}

    %{
      "proofPresent" => Map.get(audit, :proof_present, false),
      "proofHash" => Map.get(audit, :proof_hash),
      "proofStatus" => Map.get(audit, :proof_status, "missing"),
      "generatedAt" => Map.get(audit, :generated_at),
      "completedCount" => Map.get(audit, :completed_count, 0),
      "failedCount" => Map.get(audit, :failed_count, 0),
      "validateCheckStatus" => Map.get(audit, :validate_check_status, "missing"),
      "blockCheckStatus" => Map.get(audit, :block_check_status, "missing"),
      "updateCheckStatus" => Map.get(audit, :update_check_status, "missing"),
      "noCodeCheckStatus" => Map.get(audit, :no_code_check_status, "missing"),
      "redactionCheckStatus" => Map.get(audit, :redaction_check_status, "missing"),
      "registryWorkflowSupported" => Map.get(audit, :registry_workflow_supported, false),
      "registryBoundary" => %{
        "validatesManifestMetadata" => Map.get(boundary, :validates_manifest_metadata, false),
        "blocksUnauditedInstalls" => Map.get(boundary, :blocks_unaudited_installs, false),
        "detectsUpdateCandidates" => Map.get(boundary, :detects_update_candidates, false),
        "loadsExtensionCode" => Map.get(boundary, :loads_extension_code, false),
        "installableCount" => Map.get(boundary, :installable_count, 0),
        "blockedCount" => Map.get(boundary, :blocked_count, 0),
        "updateCandidateCount" => Map.get(boundary, :update_candidate_count, 0),
        "blockedUpdateCount" => Map.get(boundary, :blocked_update_count, 0)
      },
      "redaction" => %{
        "containsRawRegistryPaths" => Map.get(redaction, :contains_raw_registry_paths, false),
        "containsDistributionUrls" => Map.get(redaction, :contains_distribution_urls, false),
        "containsPackageNames" => Map.get(redaction, :contains_package_names, false),
        "containsManifestContents" => Map.get(redaction, :contains_manifest_contents, false)
      }
    }
  end

  defp format_registry_audit(_), do: format_registry_audit(%{})

  defp format_wasm_lifecycle(lifecycle) when is_map(lifecycle) do
    boundary = lifecycle[:lifecycle_boundary] || %{}
    redaction = lifecycle[:redaction] || %{}

    %{
      "proofPresent" => Map.get(lifecycle, :proof_present, false),
      "proofHash" => Map.get(lifecycle, :proof_hash),
      "proofStatus" => Map.get(lifecycle, :proof_status, "missing"),
      "generatedAt" => Map.get(lifecycle, :generated_at),
      "completedCount" => Map.get(lifecycle, :completed_count, 0),
      "failedCount" => Map.get(lifecycle, :failed_count, 0),
      "discoverCheckStatus" => Map.get(lifecycle, :discover_check_status, "missing"),
      "invokeCheckStatus" => Map.get(lifecycle, :invoke_check_status, "missing"),
      "statusCheckStatus" => Map.get(lifecycle, :status_check_status, "missing"),
      "stopCheckStatus" => Map.get(lifecycle, :stop_check_status, "missing"),
      "redactionCheckStatus" => Map.get(lifecycle, :redaction_check_status, "missing"),
      "lifecycleSupported" => Map.get(lifecycle, :lifecycle_supported, false),
      "lifecycleBoundary" => %{
        "host" => Map.get(boundary, :host),
        "discoverEmitsRedactedStartStop" =>
          Map.get(boundary, :discover_emits_redacted_start_stop, false),
        "invokeEmitsRedactedStartStop" =>
          Map.get(boundary, :invoke_emits_redacted_start_stop, false),
        "statusTracksRunningSidecar" => Map.get(boundary, :status_tracks_running_sidecar, false),
        "stopTerminatesSidecar" => Map.get(boundary, :stop_terminates_sidecar, false),
        "toolCount" => Map.get(boundary, :tool_count, 0)
      },
      "redaction" => %{
        "containsRawCwd" => Map.get(redaction, :contains_raw_cwd, false),
        "containsRawSessionIds" => Map.get(redaction, :contains_raw_session_ids, false),
        "containsRawToolNames" => Map.get(redaction, :contains_raw_tool_names, false),
        "containsRawParams" => Map.get(redaction, :contains_raw_params, false)
      }
    }
  end

  defp format_wasm_lifecycle(_), do: format_wasm_lifecycle(%{})

  defp host_runtime(
         _cwd,
         loaded_count,
         load_errors,
         validation_errors,
         tool_conflicts,
         manifest_status
       ) do
    host_counts = manifest_status[:host_type_counts] || %{}

    %{
      "beam" => %{
        "status" =>
          beam_host_status(loaded_count, load_errors, validation_errors, manifest_status),
        "loadedExtensionCount" => loaded_count,
        "loadErrorCount" => load_errors,
        "validationErrorCount" => validation_errors,
        "manifestCount" => Map.get(host_counts, "beam", 0)
      },
      "wasm" => wasm_host_runtime(tool_conflicts[:wasm], Map.get(host_counts, "wasm", 0)),
      "mcp" => manifest_only_host_runtime(Map.get(host_counts, "mcp", 0)),
      "external" => manifest_only_host_runtime(Map.get(host_counts, "external", 0)),
      "cleanup" => %{
        "includesRawSourcePaths" => false,
        "includesLoadErrorMessages" => false,
        "loadsDefaultDirectoryCode" => false
      }
    }
  end

  defp safe_manifest_status(cwd) do
    ExtensionDiagnostics.status(project_dir: cwd)
  rescue
    _ -> %{host_type_counts: %{}}
  end

  defp beam_host_status(_loaded_count, _load_errors, _validation_errors, %{
         execution: %{enabled: false}
       }),
       do: "disabled"

  defp beam_host_status(_loaded_count, load_errors, validation_errors, _manifest_status)
       when load_errors > 0 or validation_errors > 0,
       do: "degraded"

  defp beam_host_status(loaded_count, _load_errors, _validation_errors, _manifest_status)
       when loaded_count > 0,
       do: "running"

  defp beam_host_status(_loaded_count, _load_errors, _validation_errors, _manifest_status),
    do: "idle"

  defp wasm_host_runtime(wasm, manifest_count) do
    formatted = format_wasm(wasm) || %{}

    %{
      "status" => wasm_host_status(formatted, manifest_count),
      "enabled" => Map.get(formatted, "enabled", false),
      "running" => Map.get(formatted, "running", false),
      "supervisorRunning" => wasm_supervisor_running?(),
      "toolCount" => Map.get(formatted, "toolCount", 0),
      "manifestCount" => manifest_count,
      "reason" => Map.get(formatted, "reason")
    }
  end

  defp wasm_host_status(%{"running" => true}, _manifest_count), do: "running"
  defp wasm_host_status(%{"enabled" => true}, _manifest_count), do: "enabled_idle"
  defp wasm_host_status(_formatted, manifest_count) when manifest_count > 0, do: "disabled"
  defp wasm_host_status(_formatted, _manifest_count), do: "not_configured"

  defp wasm_supervisor_running? do
    Code.ensure_loaded?(CodingAgent.Wasm.SidecarSupervisor) and
      is_pid(Process.whereis(CodingAgent.Wasm.SidecarSupervisor))
  end

  defp manifest_only_host_runtime(manifest_count) do
    %{
      "status" => if(manifest_count > 0, do: "manifest_only", else: "not_configured"),
      "manifestCount" => manifest_count,
      "runtimeManagedByLemon" => false
    }
  end

  defp status(false, _load_errors, _validation_errors, _tool_conflicts), do: "disabled"

  defp status(true, load_errors, validation_errors, tool_conflicts) do
    cond do
      load_errors > 0 -> "degraded"
      validation_errors > 0 -> "degraded"
      (tool_conflicts[:shadowed_count] || 0) > 0 -> "conflicts"
      true -> "ok"
    end
  end

  defp format_source(:builtin), do: %{"type" => "builtin"}

  defp format_source({:extension, module}) do
    %{"type" => "extension", "module" => module_name(module)}
  end

  defp format_source({:wasm, meta}) do
    %{"type" => "wasm", "nameHash" => hash_optional(wasm_name(meta))}
  end

  defp format_source({:mcp, server}) do
    %{"type" => "mcp", "serverHash" => hash_optional(to_string(server))}
  end

  defp format_source(other), do: %{"type" => safe_string(other)}

  defp wasm_name(meta) when is_map(meta),
    do: meta[:name] || meta["name"] || meta[:path] || meta["path"]

  defp wasm_name(meta), do: safe_string(meta)

  defp module_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp module_name(value), do: safe_string(value)

  defp error_type(%struct{}), do: module_name(struct)
  defp error_type(error) when is_atom(error), do: to_string(error)
  defp error_type(error), do: error |> inspect() |> hash_optional()

  defp hash_optional(nil), do: nil

  defp hash_optional(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp safe_string(nil), do: "unknown"
  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(value), do: inspect(value)

  defp truthy?(value), do: value in [true, "true", 1]

  defp enabled?(value) when value in [false, "false", 0], do: false
  defp enabled?(_), do: true
end
