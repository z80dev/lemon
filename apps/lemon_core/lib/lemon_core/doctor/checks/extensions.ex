defmodule LemonCore.Doctor.Checks.Extensions do
  @moduledoc "Checks extension/plugin supportability proof state."

  alias LemonCore.Doctor.Check
  alias LemonCore.Doctor.ExtensionDiagnostics

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    [
      check_extension_tool_telemetry(project_dir),
      check_wasm_tool_telemetry(project_dir),
      check_wasm_policy(project_dir),
      check_registry_audit(project_dir),
      check_wasm_lifecycle(project_dir)
    ]
  end

  defp check_extension_tool_telemetry(project_dir) do
    telemetry =
      [project_dir: project_dir]
      |> ExtensionDiagnostics.status()
      |> Map.get(:execution_telemetry, %{})

    cond do
      Map.get(telemetry, :emits_redacted_start_stop_exception) == true and
          Map.get(telemetry, :blocks_disabled_explicit_paths) == true ->
        Check.pass(
          "extensions.telemetry",
          "Extension host proof is completed with redacted telemetry and disabled-mode execution blocking."
        )

      Map.get(telemetry, :proof_present) == true ->
        Check.warn(
          "extensions.telemetry",
          "Extension host proof exists, but telemetry or disabled-mode blocking is incomplete.",
          "Run `MIX_ENV=test mix run scripts/live_extension_host_smoke.exs` and inspect `.lemon/proofs/extension-host-smoke-latest.json`."
        )

      true ->
        Check.skip(
          "extensions.telemetry",
          "Extension host telemetry proof has not been generated yet."
        )
    end
  rescue
    error ->
      Check.warn(
        "extensions.telemetry",
        "Extension telemetry diagnostics are unavailable.",
        Exception.message(error)
      )
  end

  defp check_wasm_tool_telemetry(project_dir) do
    telemetry =
      [project_dir: project_dir]
      |> ExtensionDiagnostics.status()
      |> Map.get(:wasm_telemetry, %{})

    cond do
      Map.get(telemetry, :emits_redacted_start_stop_exception) == true ->
        Check.pass(
          "extensions.wasm_telemetry",
          "WASM tool wrapper proof is completed with redacted start/stop/exception telemetry."
        )

      Map.get(telemetry, :proof_present) == true ->
        Check.warn(
          "extensions.wasm_telemetry",
          "WASM tool wrapper proof exists, but telemetry or redaction checks are incomplete.",
          "Run `MIX_ENV=test mix run scripts/live_wasm_telemetry_smoke.exs` and inspect `.lemon/proofs/wasm-tool-telemetry-latest.json`."
        )

      true ->
        Check.skip(
          "extensions.wasm_telemetry",
          "WASM tool wrapper telemetry proof has not been generated yet."
        )
    end
  rescue
    error ->
      Check.warn(
        "extensions.wasm_telemetry",
        "WASM telemetry diagnostics are unavailable.",
        Exception.message(error)
      )
  end

  defp check_wasm_policy(project_dir) do
    policy =
      [project_dir: project_dir]
      |> ExtensionDiagnostics.status()
      |> Map.get(:wasm_policy, %{})

    cond do
      Map.get(policy, :capability_approval_defaults) == true and
          Map.get(policy, :explicit_override_supported) == true ->
        Check.pass(
          "extensions.wasm_policy",
          "WASM policy proof is completed for risky-capability approval defaults."
        )

      Map.get(policy, :proof_present) == true ->
        Check.warn(
          "extensions.wasm_policy",
          "WASM policy proof exists, but approval-default checks are incomplete.",
          "Run `MIX_ENV=test mix run scripts/live_wasm_policy_smoke.exs` and inspect `.lemon/proofs/wasm-policy-latest.json`."
        )

      true ->
        Check.skip(
          "extensions.wasm_policy",
          "WASM policy proof has not been generated yet."
        )
    end
  rescue
    error ->
      Check.warn(
        "extensions.wasm_policy",
        "WASM policy diagnostics are unavailable.",
        Exception.message(error)
      )
  end

  defp check_registry_audit(project_dir) do
    registry_audit =
      [project_dir: project_dir]
      |> ExtensionDiagnostics.status()
      |> Map.get(:registry_audit, %{})

    cond do
      Map.get(registry_audit, :registry_workflow_supported) == true ->
        Check.pass(
          "extensions.registry_audit",
          "Extension registry audit proof is completed for code-free install/update review."
        )

      Map.get(registry_audit, :proof_present) == true ->
        Check.warn(
          "extensions.registry_audit",
          "Extension registry audit proof exists, but install/update or redaction checks are incomplete.",
          "Run `MIX_ENV=test mix run scripts/live_extension_registry_audit_smoke.exs` and inspect `.lemon/proofs/extension-registry-audit-latest.json`."
        )

      true ->
        Check.skip(
          "extensions.registry_audit",
          "Extension registry audit proof has not been generated yet."
        )
    end
  rescue
    error ->
      Check.warn(
        "extensions.registry_audit",
        "Extension registry audit diagnostics are unavailable.",
        Exception.message(error)
      )
  end

  defp check_wasm_lifecycle(project_dir) do
    lifecycle =
      [project_dir: project_dir]
      |> ExtensionDiagnostics.status()
      |> Map.get(:wasm_lifecycle, %{})

    cond do
      Map.get(lifecycle, :lifecycle_supported) == true ->
        Check.pass(
          "extensions.wasm_lifecycle",
          "WASM sidecar lifecycle proof is completed for redacted discover/invoke, status, and stop behavior."
        )

      Map.get(lifecycle, :proof_present) == true ->
        Check.warn(
          "extensions.wasm_lifecycle",
          "WASM sidecar lifecycle proof exists, but lifecycle or redaction checks are incomplete.",
          "Run `MIX_ENV=test mix run scripts/live_wasm_lifecycle_smoke.exs` and inspect `.lemon/proofs/wasm-lifecycle-latest.json`."
        )

      true ->
        Check.skip(
          "extensions.wasm_lifecycle",
          "WASM sidecar lifecycle proof has not been generated yet."
        )
    end
  rescue
    error ->
      Check.warn(
        "extensions.wasm_lifecycle",
        "WASM lifecycle diagnostics are unavailable.",
        Exception.message(error)
      )
  end
end
