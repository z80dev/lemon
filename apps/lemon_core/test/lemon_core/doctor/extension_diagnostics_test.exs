defmodule LemonCore.Doctor.ExtensionDiagnosticsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.ExtensionDiagnostics

  test "reports redacted extension tool telemetry proof status" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "extension-host-smoke-latest.json"]),
      Jason.encode!(%{
        status: "completed",
        generated_at: "2026-05-17T00:44:58.671764Z",
        completed_count: 7,
        failed_count: 0,
        checks: [
          %{name: "extension_tool_execution_emits_redacted_telemetry", status: "completed"},
          %{name: "extensions_disabled_blocks_explicit_path_execution", status: "completed"},
          %{
            name: "extensions_env_disabled_blocks_explicit_path_execution",
            status: "completed"
          }
        ],
        redaction: %{
          contains_raw_paths: false,
          contains_file_contents: false,
          contains_load_error_messages: false,
          contains_tool_result_payload: false
        }
      })
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.execution_telemetry.proof_present == true
    assert status.execution_telemetry.proof_status == "completed"
    assert status.execution_telemetry.completed_count == 7
    assert status.execution_telemetry.failed_count == 0
    assert status.execution_telemetry.telemetry_check_status == "completed"
    assert status.execution_telemetry.disabled_check_status == "completed"
    assert status.execution_telemetry.env_disabled_check_status == "completed"
    assert status.execution_telemetry.emits_redacted_start_stop_exception == true
    assert status.execution_telemetry.blocks_disabled_explicit_paths == true
    assert is_binary(status.execution_telemetry.proof_hash)

    refute inspect(status.execution_telemetry) =~ tmp_dir
  end

  test "reports redacted wasm tool telemetry proof status" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_wasm_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "wasm-tool-telemetry-latest.json"]),
      Jason.encode!(%{
        status: "completed",
        generated_at: "2026-05-17T01:18:56.838802Z",
        completed_count: 4,
        failed_count: 0,
        checks: [
          %{name: "wasm_tool_success_emits_redacted_start_stop_telemetry", status: "completed"},
          %{name: "wasm_tool_error_emits_redacted_error_status", status: "completed"},
          %{name: "wasm_tool_exit_emits_redacted_exception_telemetry", status: "completed"},
          %{name: "wasm_tool_telemetry_omits_raw_sensitive_values", status: "completed"}
        ],
        host_boundary: %{
          host: "wasm",
          emits_start_stop_exception: true,
          uses_hashed_wasm_paths: true,
          tool_count: 3
        },
        redaction: %{
          contains_raw_paths: false,
          contains_raw_params: false,
          contains_raw_tool_call_ids: false,
          contains_sidecar_error_text: false,
          contains_tool_result_payload: false
        }
      })
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.wasm_telemetry.proof_present == true
    assert status.wasm_telemetry.proof_status == "completed"
    assert status.wasm_telemetry.completed_count == 4
    assert status.wasm_telemetry.failed_count == 0
    assert status.wasm_telemetry.success_check_status == "completed"
    assert status.wasm_telemetry.error_check_status == "completed"
    assert status.wasm_telemetry.exception_check_status == "completed"
    assert status.wasm_telemetry.redaction_check_status == "completed"
    assert status.wasm_telemetry.emits_redacted_start_stop_exception == true
    assert status.wasm_telemetry.host_boundary.host == "wasm"
    assert status.wasm_telemetry.host_boundary.uses_hashed_wasm_paths == true
    assert status.wasm_telemetry.host_boundary.tool_count == 3
    assert status.wasm_telemetry.redaction.contains_raw_params == false
    assert is_binary(status.wasm_telemetry.proof_hash)

    refute inspect(status.wasm_telemetry) =~ tmp_dir
  end

  test "reports redacted wasm policy proof status" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_wasm_policy_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "wasm-policy-latest.json"]),
      Jason.encode!(%{
        status: "completed",
        generated_at: "2026-05-17T01:26:08.374597Z",
        completed_count: 5,
        failed_count: 0,
        checks: [
          %{name: "wasm_policy_http_requires_approval", status: "completed"},
          %{name: "wasm_policy_tool_invoke_requires_approval", status: "completed"},
          %{name: "wasm_policy_exec_requires_approval", status: "completed"},
          %{name: "wasm_policy_safe_capabilities_execute_without_approval", status: "completed"},
          %{name: "wasm_policy_explicit_never_overrides_default_approval", status: "completed"}
        ],
        policy_boundary: %{
          http_requires_approval_by_default: true,
          tool_invoke_requires_approval_by_default: true,
          exec_requires_approval_by_default: true,
          safe_capabilities_execute_without_approval: true,
          explicit_never_can_override_default: true
        },
        redaction: %{
          contains_raw_paths: false,
          contains_raw_params: false,
          contains_raw_tool_call_ids: false
        }
      })
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.wasm_policy.proof_present == true
    assert status.wasm_policy.proof_status == "completed"
    assert status.wasm_policy.completed_count == 5
    assert status.wasm_policy.failed_count == 0
    assert status.wasm_policy.http_check_status == "completed"
    assert status.wasm_policy.tool_invoke_check_status == "completed"
    assert status.wasm_policy.exec_check_status == "completed"
    assert status.wasm_policy.safe_check_status == "completed"
    assert status.wasm_policy.override_check_status == "completed"
    assert status.wasm_policy.capability_approval_defaults == true
    assert status.wasm_policy.explicit_override_supported == true
    assert status.wasm_policy.policy_boundary.exec_requires_approval_by_default == true
    assert status.wasm_policy.redaction.contains_raw_params == false
    assert is_binary(status.wasm_policy.proof_hash)

    refute inspect(status.wasm_policy) =~ tmp_dir
  end

  test "reports redacted extension registry audit proof status" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_registry_audit_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "extension-registry-audit-latest.json"]),
      Jason.encode!(%{
        status: "completed",
        generated_at: "2026-05-17T02:02:00Z",
        completed_count: 5,
        failed_count: 0,
        checks: [
          %{name: "extension_registry_validates_code_free_index", status: "completed"},
          %{name: "extension_registry_blocks_unaudited_install", status: "completed"},
          %{name: "extension_registry_detects_audited_update", status: "completed"},
          %{name: "extension_registry_audit_does_not_load_code", status: "completed"},
          %{name: "extension_registry_audit_redacts_sensitive_values", status: "completed"}
        ],
        registry_boundary: %{
          validates_manifest_metadata: true,
          blocks_unaudited_installs: true,
          detects_update_candidates: true,
          loads_extension_code: false,
          installable_count: 2,
          blocked_count: 2,
          update_candidate_count: 1,
          blocked_update_count: 1
        },
        redaction: %{
          contains_raw_registry_paths: false,
          contains_distribution_urls: false,
          contains_package_names: false,
          contains_manifest_contents: false
        }
      })
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.registry_audit.proof_present == true
    assert status.registry_audit.proof_status == "completed"
    assert status.registry_audit.completed_count == 5
    assert status.registry_audit.failed_count == 0
    assert status.registry_audit.validate_check_status == "completed"
    assert status.registry_audit.block_check_status == "completed"
    assert status.registry_audit.update_check_status == "completed"
    assert status.registry_audit.no_code_check_status == "completed"
    assert status.registry_audit.redaction_check_status == "completed"
    assert status.registry_audit.registry_workflow_supported == true
    assert status.registry_audit.registry_boundary.loads_extension_code == false
    assert status.registry_audit.registry_boundary.update_candidate_count == 1
    assert status.registry_audit.redaction.contains_package_names == false
    assert is_binary(status.registry_audit.proof_hash)

    refute inspect(status.registry_audit) =~ tmp_dir
  end

  test "reports redacted wasm lifecycle proof status" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_wasm_lifecycle_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join([tmp_dir, ".lemon", "proofs"]))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "proofs", "wasm-lifecycle-latest.json"]),
      Jason.encode!(%{
        status: "completed",
        generated_at: "2026-05-17T02:29:28.355Z",
        completed_count: 5,
        failed_count: 0,
        checks: [
          %{name: "wasm_lifecycle_discover_emits_redacted_start_stop", status: "completed"},
          %{name: "wasm_lifecycle_invoke_emits_redacted_start_stop", status: "completed"},
          %{name: "wasm_lifecycle_status_tracks_running_sidecar", status: "completed"},
          %{name: "wasm_lifecycle_stop_terminates_sidecar", status: "completed"},
          %{name: "wasm_lifecycle_telemetry_omits_raw_sensitive_values", status: "completed"}
        ],
        lifecycle_boundary: %{
          host: "wasm",
          discover_emits_redacted_start_stop: true,
          invoke_emits_redacted_start_stop: true,
          status_tracks_running_sidecar: true,
          stop_terminates_sidecar: true,
          tool_count: 1
        },
        redaction: %{
          contains_raw_cwd: false,
          contains_raw_session_ids: false,
          contains_raw_tool_names: false,
          contains_raw_params: false
        }
      })
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.wasm_lifecycle.proof_present == true
    assert status.wasm_lifecycle.proof_status == "completed"
    assert status.wasm_lifecycle.completed_count == 5
    assert status.wasm_lifecycle.failed_count == 0
    assert status.wasm_lifecycle.discover_check_status == "completed"
    assert status.wasm_lifecycle.invoke_check_status == "completed"
    assert status.wasm_lifecycle.status_check_status == "completed"
    assert status.wasm_lifecycle.stop_check_status == "completed"
    assert status.wasm_lifecycle.redaction_check_status == "completed"
    assert status.wasm_lifecycle.lifecycle_supported == true
    assert status.wasm_lifecycle.lifecycle_boundary.host == "wasm"
    assert status.wasm_lifecycle.lifecycle_boundary.stop_terminates_sidecar == true
    assert status.wasm_lifecycle.redaction.contains_raw_tool_names == false
    assert is_binary(status.wasm_lifecycle.proof_hash)

    refute inspect(status.wasm_lifecycle) =~ tmp_dir
  end

  test "reports disabled extension execution policy without loading code" do
    System.put_env("LEMON_EXTENSIONS_ENABLED", "false")
    on_exit(fn -> System.delete_env("LEMON_EXTENSIONS_ENABLED") end)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_disabled_test_#{System.unique_integer([:positive])}"
      )

    extension_dir = Path.join([tmp_dir, ".lemon", "extensions"])
    File.mkdir_p!(extension_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "config.toml"]),
      """
      [runtime.extensions]
      enabled = false
      auto_load_default_paths = true
      """
    )

    File.write!(
      Path.join(extension_dir, "lemon_extension.json"),
      Jason.encode!(%{
        schema_version: 1,
        name: "disabled-private-extension",
        version: "1.0.0",
        hosts: [%{type: "beam"}]
      })
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.execution.enabled == false
    assert status.host_runtime.hosts["beam"].status == "disabled"
    assert status.cleanup.loads_extension_code == false
    refute inspect(status) =~ "disabled-private-extension"
  end
end
