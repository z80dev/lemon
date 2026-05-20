defmodule LemonCore.Doctor.Checks.OpenAICompat do
  @moduledoc "Checks OpenAI-compatible API preview proof readiness."

  alias LemonCore.Doctor.{Check, ProofDiagnostics}

  @checks [
    {"openai_compat_health_and_capabilities", "health/capabilities"},
    {"openai_compat_chat_wait", "chat wait"},
    {"openai_compat_image_input_metadata", "image metadata"},
    {"openai_compat_data_url_image_pass_through", "data URL image"},
    {"openai_compat_non_vision_image_rejection", "non-vision guard"},
    {"openai_compat_remote_image_url_fetch_policy", "remote image policy"},
    {"openai_compat_external_fetch_client", "external fetch client"},
    {"openai_compat_external_openai_sdk_client", "OpenAI Node SDK client"},
    {"openai_compat_external_python_sdk_client", "OpenAI Python SDK client"},
    {"openai_compat_response_continuation", "response continuation"},
    {"openai_compat_stored_response", "stored response"},
    {"openai_compat_chat_stream", "chat stream"},
    {"openai_compat_run_status_redaction", "run status redaction"},
    {"openai_compat_run_cancel", "run cancel"}
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    [check_api_preview(proofs)]
  rescue
    error ->
      [
        Check.warn(
          "openai_compat.api_preview",
          "OpenAI-compatible API proof diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_api_preview(proofs) do
    statuses = check_statuses(proofs)
    completed = labels(statuses, "completed")
    failed = labels(statuses, "failed")
    missing = labels(statuses, "missing")

    cond do
      completed == [] and failed == [] ->
        Check.skip(
          "openai_compat.api_preview",
          "OpenAI-compatible API preview proof has not been generated yet."
        )

      failed != [] or missing != [] ->
        Check.warn(
          "openai_compat.api_preview",
          "OpenAI-compatible API preview proof is incomplete: completed #{label_list(completed)}#{status_suffix("failed", failed)}#{status_suffix("missing", missing)}.",
          remediation()
        )

      true ->
        Check.pass(
          "openai_compat.api_preview",
          "OpenAI-compatible API preview proof is completed for #{length(completed)} checks, including external fetch, OpenAI Node SDK, and OpenAI Python SDK clients."
        )
    end
  end

  defp check_statuses(proofs) do
    Enum.map(@checks, fn {name, label} ->
      %{
        name: name,
        label: label,
        status: check_status(proofs, name)
      }
    end)
  end

  defp check_status(proofs, name) do
    proofs
    |> Map.get(:latest_checks, [])
    |> Enum.filter(&(Map.get(&1, :name) == name))
    |> Enum.map(&Map.get(&1, :status))
    |> best_status()
  end

  defp best_status(statuses) do
    cond do
      "completed" in statuses -> "completed"
      "failed" in statuses -> "failed"
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
    "Run MIX_ENV=test mix run scripts/live_openai_compat_smoke.exs and keep the redacted proof at .lemon/proofs/openai-compat-smoke-latest.json."
  end
end
