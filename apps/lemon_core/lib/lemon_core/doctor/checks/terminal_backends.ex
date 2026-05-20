defmodule LemonCore.Doctor.Checks.TerminalBackends do
  @moduledoc "Checks terminal backend live-proof readiness from redacted proof artifacts."

  alias LemonCore.Doctor.{Check, ProofDiagnostics}

  @backends [
    {"terminal_backend_local", "local"},
    {"terminal_backend_local_pty", "local PTY"},
    {"terminal_backend_docker", "Docker"},
    {"terminal_backend_ssh", "SSH"}
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    proofs = ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)

    [check_live_backend_proof(proofs)]
  rescue
    error ->
      [
        Check.warn(
          "terminal.backends_live",
          "Terminal backend proof diagnostics are unavailable.",
          Exception.message(error)
        )
      ]
  end

  defp check_live_backend_proof(proofs) do
    statuses = backend_statuses(proofs)
    completed = backend_labels(statuses, "completed")
    failed = backend_labels(statuses, "failed")
    skipped = backend_labels(statuses, "skipped")
    missing = backend_labels(statuses, "missing")

    cond do
      completed == [] and failed == [] and skipped == [] ->
        Check.skip(
          "terminal.backends_live",
          "Terminal backend live proof has not been generated yet."
        )

      failed != [] or missing != [] ->
        Check.warn(
          "terminal.backends_live",
          "Terminal backend live proof is incomplete: completed #{label_list(completed)}#{status_suffix("failed", failed)}#{status_suffix("skipped", skipped)}#{status_suffix("missing", missing)}.",
          remediation()
        )

      true ->
        Check.pass(
          "terminal.backends_live",
          "Terminal backend live proof is completed for #{label_list(completed)}#{status_suffix("skipped", skipped)}."
        )
    end
  end

  defp backend_statuses(proofs) do
    Enum.map(@backends, fn {check_name, label} ->
      %{
        check_name: check_name,
        label: label,
        status: backend_status(proofs, check_name)
      }
    end)
  end

  defp backend_status(proofs, check_name) do
    proofs
    |> Map.get(:latest_checks, [])
    |> Enum.filter(&(Map.get(&1, :name) == check_name))
    |> Enum.map(&Map.get(&1, :status))
    |> best_status()
  end

  defp best_status(statuses) do
    cond do
      "completed" in statuses -> "completed"
      "failed" in statuses -> "failed"
      "skipped" in statuses -> "skipped"
      true -> "missing"
    end
  end

  defp backend_labels(statuses, status) do
    statuses
    |> Enum.filter(&(&1.status == status))
    |> Enum.map(& &1.label)
  end

  defp label_list([]), do: "none"
  defp label_list(labels), do: Enum.join(labels, ", ")

  defp status_suffix(_label, []), do: ""
  defp status_suffix(label, values), do: "; #{label} #{Enum.join(values, ", ")}"

  defp remediation do
    "Run MIX_ENV=test mix run scripts/live_terminal_backend_smoke.exs and keep the redacted proof at .lemon/proofs/terminal-backend-latest.json."
  end
end
