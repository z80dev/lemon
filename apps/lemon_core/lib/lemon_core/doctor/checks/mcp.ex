defmodule LemonCore.Doctor.Checks.MCP do
  @moduledoc "Checks MCP preview proof readiness from redacted smoke artifacts."

  alias LemonCore.Doctor.{Check, ProofDiagnostics}

  @proofs [
    %{
      label: "stdio",
      proof_object: "mcp_stdio_smoke",
      required_count: 17,
      required_checks: [
        {"mcp_stdio_degraded_startup_missing_command", "stdio degraded startup"},
        {"mcp_stdio_client_initializes", "stdio initialize"},
        {"mcp_stdio_lists_tools", "stdio tools"},
        {"mcp_stdio_lists_resources", "stdio resources"},
        {"mcp_stdio_reads_resource", "stdio resource read"},
        {"mcp_stdio_lists_prompts", "stdio prompts"},
        {"mcp_stdio_gets_prompt", "stdio prompt get"},
        {"mcp_stdio_calls_tool_success", "stdio tool success"},
        {"mcp_stdio_calls_tool_error", "stdio tool error"},
        {"mcp_source_discovers_prefixed_stdio_tools", "stdio source discovery"},
        {"mcp_source_invokes_resource_and_prompt_utilities", "stdio utility invocation"},
        {"mcp_registry_exposes_prefixed_stdio_tools", "stdio registry"},
        {"mcp_source_applies_stdio_filters", "stdio filters"},
        {"mcp_server_accepts_spec_initialized_notification", "initialized notification"},
        {"mcp_stdio_sampling_callback_wrapper", "stdio sampling callback"},
        {"mcp_stdio_sampling_reviewed_model_policy", "stdio sampling policy"},
        {"mcp_stdio_sampling_ops_approval_bridge", "stdio sampling approval"}
      ]
    },
    %{
      label: "Streamable HTTP",
      proof_object: "mcp_http_smoke",
      required_count: 24,
      required_checks: [
        {"mcp_http_client_initializes", "HTTP initialize"},
        {"mcp_http_lists_tools", "HTTP tools"},
        {"mcp_http_calls_tool_success", "HTTP tool success"},
        {"mcp_http_calls_tool_error", "HTTP tool error"},
        {"mcp_http_lists_resources", "HTTP resources"},
        {"mcp_http_reads_resource", "HTTP resource read"},
        {"mcp_http_lists_prompts", "HTTP prompts"},
        {"mcp_http_gets_prompt", "HTTP prompt get"},
        {"mcp_http_streamable_sse_response_and_session_headers", "HTTP stream/session"},
        {"mcp_http_oauth_protected_resource_metadata", "HTTP protected resource metadata"},
        {"mcp_http_oauth_authorization_server_metadata", "HTTP auth server metadata"},
        {"mcp_http_oauth_client_credentials_token_acquisition", "HTTP client credentials"},
        {"mcp_http_oauth_client_credentials_token_refresh", "HTTP token refresh"},
        {"mcp_http_oauth_refresh_token_grant", "HTTP refresh grant"},
        {"mcp_http_oauth_client_secret_basic_token_auth", "HTTP client secret basic"},
        {"mcp_http_oauth_pkce_authorization_code", "HTTP PKCE"},
        {"mcp_http_oauth_token_cache_resume", "HTTP token cache resume"},
        {"mcp_source_discovers_prefixed_http_tools", "HTTP source discovery"},
        {"mcp_source_invokes_http_tool", "HTTP source tool invocation"},
        {"mcp_source_invokes_http_resource_and_prompt_utilities", "HTTP utility invocation"},
        {"mcp_registry_exposes_prefixed_http_tools", "HTTP registry"},
        {"mcp_source_status_reports_http_capabilities", "HTTP capability status"},
        {"mcp_source_applies_http_filters", "HTTP filters"},
        {"mcp_source_http_oauth_loopback_callback", "HTTP OAuth loopback callback"}
      ]
    },
    %{
      label: "SSE",
      proof_object: "mcp_sse_smoke",
      required_count: 14,
      required_checks: [
        {"mcp_sse_client_initializes", "SSE initialize"},
        {"mcp_sse_lists_tools", "SSE tools"},
        {"mcp_sse_calls_tool_success", "SSE tool success"},
        {"mcp_sse_calls_tool_error", "SSE tool error"},
        {"mcp_sse_lists_resources", "SSE resources"},
        {"mcp_sse_reads_resource", "SSE resource read"},
        {"mcp_sse_lists_prompts", "SSE prompts"},
        {"mcp_sse_gets_prompt", "SSE prompt get"},
        {"mcp_source_discovers_prefixed_sse_tools", "SSE source discovery"},
        {"mcp_source_invokes_sse_tool", "SSE source tool invocation"},
        {"mcp_source_invokes_sse_resource_and_prompt_utilities", "SSE utility invocation"},
        {"mcp_registry_exposes_prefixed_sse_tools", "SSE registry"},
        {"mcp_source_status_reports_sse_capabilities", "SSE capability status"},
        {"mcp_source_applies_sse_filters", "SSE filters"}
      ]
    }
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    [check_mcp_preview(proofs)]
  rescue
    error ->
      [
        Check.warn(
          "mcp.preview",
          "MCP proof diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_mcp_preview(proofs) do
    statuses = proof_statuses(proofs)
    completed = labels(statuses, "completed")
    failed = labels(statuses, "failed")
    missing = labels(statuses, "missing")

    cond do
      completed == [] and failed == [] ->
        Check.skip("mcp.preview", "MCP preview proof has not been generated yet.")

      failed != [] or missing != [] ->
        Check.warn(
          "mcp.preview",
          "MCP preview proof is incomplete: completed #{label_list(completed)}#{status_suffix("failed", failed)}#{status_suffix("missing", missing)}.",
          remediation()
        )

      true ->
        Check.pass(
          "mcp.preview",
          "MCP preview proof is completed for stdio, Streamable HTTP, and SSE transports."
        )
    end
  end

  defp proof_statuses(proofs) do
    Enum.map(@proofs, fn proof ->
      %{
        label: proof.label,
        status: proof_status(proofs, proof)
      }
    end)
  end

  defp proof_status(proofs, proof) do
    proof_artifact_status = recent_proof_status(proofs, proof.proof_object, proof.required_count)
    check_status = required_check_status(proofs, proof.required_checks)

    best_status([proof_artifact_status, check_status])
  end

  defp recent_proof_status(proofs, proof_object, required_count) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.filter(&(Map.get(&1, :proof_object) == proof_object))
    |> Enum.map(fn proof ->
      cond do
        Map.get(proof, :status) == "completed" and
          Map.get(proof, :completed_count) == required_count and
            Map.get(proof, :failed_count) == 0 ->
          "completed"

        Map.get(proof, :status) == "failed" or Map.get(proof, :failed_count, 0) > 0 ->
          "failed"

        true ->
          "missing"
      end
    end)
    |> best_status()
  end

  defp required_check_status(proofs, required_checks) do
    check_statuses = Map.get(proofs, :latest_checks, [])

    required_checks
    |> Enum.map(fn {name, _label} ->
      check_statuses
      |> Enum.filter(&(Map.get(&1, :name) == name))
      |> Enum.map(&Map.get(&1, :status))
      |> best_status()
    end)
    |> best_status()
  end

  defp best_status(statuses) do
    cond do
      "failed" in statuses -> "failed"
      "missing" in statuses -> "missing"
      "completed" in statuses -> "completed"
      true -> "missing"
    end
  end

  defp labels(statuses, status) do
    statuses
    |> Enum.filter(&(&1.status == status))
    |> Enum.map(& &1.label)
  end

  defp label_list([]), do: "none"
  defp label_list(labels), do: Enum.join(labels, ", ")

  defp status_suffix(_label, []), do: ""
  defp status_suffix(label, values), do: "; #{label} #{Enum.join(values, ", ")}"

  defp remediation do
    "Run MIX_ENV=test mix run scripts/live_mcp_stdio_smoke.exs, MIX_ENV=test mix run scripts/live_mcp_http_smoke.exs, and MIX_ENV=test mix run scripts/live_mcp_sse_smoke.exs; keep their redacted proof artifacts under .lemon/proofs/."
  end
end
